import { readFileSync, statSync } from "node:fs";

// proof-on-file — the read the customer-credit-verification skill's Step 2 gate uses to
// decide whether Caroline may ask a customer for proof (firstmate 761, captain standing
// order 2026-10-16: never re-ask a user who already sent documents; ask ONCE when there
// is definitively none).
//
// Source: credit-trust's merged export (the SAME file the credit-retro take-back gate and the
// verify notes read), refreshed hourly. Completeness is ONE contract shared with
// scripts/credit_review/proof_parts.py and pinned for both sides by
// scripts/tests/fixtures/proof-parts-contract.json. Every part below must be present once,
// not flagged stale/missing (any truthy value), and carry its OWN fresh timezone-aware
// generated_at (`core` has no stale key: its stamp is its freshness; stale:false never
// excuses an old stamp):
//   core         verifications / approved documents
//   cs-intercom  proof sent in Intercom (the exact legacy label "cs-systemic intercom+gmail"
//                is read as this part, Intercom only)
//   cs-gmail     documents emailed to support@
// Any other part flagged stale or missing makes the export unknown too. While cs-gmail is
// unusable EVERYONE is unknown (captain via firstmate 035, "when in doubt, don't send"): a
// snapshot of who emailed support@ cannot cover mail sent after it, so gmail_contacts_90d
// never narrows the hold.
//
// Answers, never a bare yes/no:
//   on_file  the customer (or one of these requests) has proof on file  -> never ask
//   none     every proof part is fresh and none lists this customer      -> ask once
//   unknown  anything else (file missing/unreadable/malformed, too old, from the future,
//            a part missing or stale)                                     -> do NOT ask,
//            route to a human; never read "unknown" as "none"
//   asked_before  set by credit_verification_check (not this file): Caroline already sent
//            the Step 2 ask in another recent conversation               -> do NOT ask again
// A check that cannot complete behaves as if it found proof (no ask), never as "none".
// Entries are held to the same rule as verify_notify.load_proof_on_file: one malformed row
// (or `users` not equal to the distinct user ids in entries[]) refuses the whole file, since
// that row may be the one customer with proof on file.

export const DEFAULT_PROOF_ON_FILE_PATH = "/var/lib/credit-trust/proof-on-file.json";
export const PROOF_MAX_AGE_MS = 3 * 60 * 60 * 1000; // same bound as takeback.PROOF_MAX_AGE
export const CLOCK_SKEW_MS = 5 * 60 * 1000;
export const LEGACY_INTERCOM_PART = "cs-systemic intercom+gmail";
export const PROOF_KINDS: ReadonlySet<string> = new Set(["approved_doc", "pending_doc", "human_approved_after_doc"]);
export const REQUIRED_PARTS: ReadonlyArray<{ label: string; match: (name: string) => boolean }> = [
  { label: "core", match: (n) => n === "core" },
  { label: "cs-intercom", match: (n) => n === "cs-intercom" || n === LEGACY_INTERCOM_PART },
  { label: "cs-gmail", match: (n) => n === "cs-gmail" },
];

export type ProofState = "on_file" | "none" | "unknown" | "asked_before";
export interface ProofOnFileResult {
  state: ProofState;
  reason: string;
}

interface Loaded {
  ok: true;
  byRequest: Set<string>;
  byUser: Set<string>;
}
type LoadResult = Loaded | { ok: false; reason: string };

function parseTime(v: unknown): number | null {
  if (typeof v !== "string" || !v) return null;
  // Require an explicit zone (Z or ±hh:mm): a naive stamp cannot be judged fresh.
  if (!/(Z|[+-]\d\d:?\d\d)$/.test(v.trim())) return null;
  const t = Date.parse(v);
  return Number.isFinite(t) ? t : null;
}

function freshness(stamp: unknown, now: number, what: string): string | null {
  const t = parseTime(stamp);
  if (t === null) return `${what} has no valid timezone-aware generated_at`;
  if (now - t > PROOF_MAX_AGE_MS) return `${what} is older than 3h`;
  if (t - now > CLOCK_SKEW_MS) return `${what} generated_at is in the future`;
  return null;
}

// Pure: validate a parsed document and index it. Exported for tests.
export function indexProofDoc(doc: unknown, now: number): LoadResult {
  if (!doc || typeof doc !== "object") return { ok: false, reason: "proof-on-file is not an object" };
  const d = doc as { generated_at?: unknown; sources?: unknown; entries?: unknown; users?: unknown };
  const top = freshness(d.generated_at, now, "proof-on-file");
  if (top) return { ok: false, reason: top };
  if (!Array.isArray(d.sources) || d.sources.length === 0) return { ok: false, reason: "proof-on-file has no sources list" };
  const sources = d.sources as Array<unknown>;
  const named = sources.filter((x): x is Record<string, unknown> => !!x && typeof x === "object");
  for (const part of REQUIRED_PARTS) {
    const found = named.filter((x) => part.match(String(x.name ?? "")));
    if (found.length === 0) return { ok: false, reason: `proof part '${part.label}' is missing` };
    if (found.length > 1) return { ok: false, reason: `proof part '${part.label}' appears ${found.length} times` };
    const src = found[0];
    if (src.stale || src.missing) return { ok: false, reason: `proof part '${part.label}' is marked ${src.missing ? "missing" : "stale"}` };
    // Always by its own stamp: stale:false never excuses an old or absent generated_at.
    const f = freshness(src.generated_at, now, `proof part '${part.label}'`);
    if (f) return { ok: false, reason: f };
  }
  const flagged = sources.filter((x) => {
    if (!x || typeof x !== "object") return true;
    const r = x as Record<string, unknown>;
    return !REQUIRED_PARTS.some((p) => p.match(String(r.name ?? ""))) && Boolean(r.stale || r.missing);
  });
  if (flagged.length) {
    return { ok: false, reason: `proof part(s) ${flagged.map((x) => `'${String((x as Record<string, unknown>)?.name ?? "?")}'`).join(", ")} marked stale or missing` };
  }
  if (!Array.isArray(d.entries)) return { ok: false, reason: "proof-on-file has no entries list" };
  const byRequest = new Set<string>();
  const byUser = new Set<string>();
  const entries = d.entries as Array<unknown>;
  for (let i = 0; i < entries.length; i++) {
    const e = entries[i];
    const r = e && typeof e === "object" && !Array.isArray(e) ? (e as Record<string, unknown>) : null;
    const uid = r?.user_id;
    const rid = r?.request_id;
    const uidOk = (typeof uid === "number" && Number.isInteger(uid)) || (typeof uid === "string" && uid.trim() !== "");
    const ridOk = rid === null || rid === undefined || typeof rid === "string";
    if (!r || !uidOk || !ridOk || typeof r.kind !== "string" || !PROOF_KINDS.has(r.kind)) {
      return { ok: false, reason: `proof-on-file has a malformed entries[${i}] (needs user_id, request_id|null and a known kind)` };
    }
    const reqId = typeof rid === "string" ? rid.trim() : "";
    if (reqId) byRequest.add(reqId);
    // Over-include: any entry for a user (request-level or not) counts as "this user sent
    // proof". The hint may be wrong in the generous direction only (no ask), never the other.
    byUser.add(String(uid).trim());
  }
  const users = d.users;
  if (typeof users !== "number" || !Number.isInteger(users) || users !== byUser.size) {
    return { ok: false, reason: `proof-on-file is inconsistent (users=${JSON.stringify(users)}, ${byUser.size} distinct user ids in entries[])` };
  }
  return { ok: true, byRequest, byUser };
}

// Only the PARSE is cached (keyed by path + mtime + size). Validation and freshness are
// recomputed on every call, because the clock moves even when the file does not.
let cache: { path: string; mtimeMs: number; size: number; doc: unknown } | null = null;

export function loadProofOnFile(path: string, now: number): LoadResult {
  let st;
  try {
    st = statSync(path);
  } catch {
    return { ok: false, reason: "proof-on-file is not readable" };
  }
  if (!(cache && cache.path === path && cache.mtimeMs === st.mtimeMs && cache.size === st.size)) {
    let doc: unknown;
    try {
      doc = JSON.parse(readFileSync(path, "utf8"));
    } catch {
      cache = null;
      return { ok: false, reason: "proof-on-file is not valid JSON" };
    }
    cache = { path, mtimeMs: st.mtimeMs, size: st.size, doc };
  }
  return indexProofDoc(cache.doc, now);
}

export function resetProofOnFileCacheForTest(): void {
  cache = null;
}

// The gate answer for one customer. `userIds`/`requestIds` come from the verified owner's
// own pending credit requests (never from customer-typed input).
export function checkProofOnFile(
  path: string,
  userIds: Iterable<string>,
  requestIds: Iterable<string>,
  now: number = Date.now(),
): ProofOnFileResult {
  const loaded = loadProofOnFile(path, now);
  if (!loaded.ok) return { state: "unknown", reason: loaded.reason };
  const users = [...userIds].map(String).filter(Boolean);
  const reqs = [...requestIds].map(String).filter(Boolean);
  if (reqs.some((r) => loaded.byRequest.has(r))) return { state: "on_file", reason: "a document is on file for one of these credits" };
  if (users.some((u) => loaded.byUser.has(u))) return { state: "on_file", reason: "this customer has sent documents before" };
  if (users.length === 0) return { state: "unknown", reason: "the submitting user of these credits is not known" };
  return { state: "none", reason: "every proof part is fresh and none lists this customer" };
}
