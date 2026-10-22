// Merge intake: one normalized record on every profile-merge / unmerge-request /
// track-merge ticket (Fable ops-takeover 2026-10-19 §4 step 1, firstmate 045).
//
// The merge executor (cmux-credit-system-lane) works these tickets oldest-first,
// paid-first and must not re-derive what Caroline already knew. create_ticket stamps
// `details.merge_intake` from what Caroline captured, and it never takes the block
// from the agent: anything the agent put under `merge_intake` is replaced.
//
//   kind            profile-merge | unmerge-request | track-merge
//   keep            the profile / track the customer wants to keep (id when a UUID can
//                   be read from the URL, else the URL as given)
//   others          the other profile(s) / track(s) (same id-or-URL rule)
//   pairs           track-merge only: [{keep, others[]}] for multi-pair requests
//   requester_owns  per id, who owns it as far as SERVER-VERIFIED facts say:
//                   "requester" | "different_user" | "unclaimed" | "unknown".
//                   Taken only from the verdict dedupe_check itself computed in THIS
//                   conversation for exactly this keep + others (DedupeVerdictStore, 2h;
//                   admin GETs + Intercom contact anti-spoof). An agent-relayed
//                   details.dedupe_verdict and the customer's say-so never set it;
//                   without a stored verdict every side is "unknown". A side is
//                   "requester" only when the requester is its sole claimant.
//   user_claim      the customer's own words: asserted_same_person, asserted_direction
//                   and customer_note from details.merge_judgment_inputs (UNTRUSTED,
//                   injection-stripped, length-capped). Evidence the executor weighs for
//                   the side the customer owns, never for the other side.
//   suspect_artist_names  unmerge only, for a suspected wrong merge with no merged id yet
//   complete        false when an id is still missing (a suspected wrong merge: the
//                   executor finds the merged profile from profile_merges first).
//
// Merge tickets also get a `merge-kind:<kind>` tag so the executor's queue read is a
// tag filter, not a description parse.

import { stripInjectionMarkers } from "./credit-verification-check.js";
import type { Verdict } from "./dedupe-check.js";

/** The stored dedupe_check verdict for (keep, others) in this conversation, if any. */
export type VerdictLookup = (keep: string | null, others: string[]) => Verdict | null;

export const MERGE_KINDS = new Set(["profile-merge", "unmerge-request", "track-merge"]);
const UUID_IN = /[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}/i;
const MAX_CLAIM = 300;
const MAX_REF = 300;

export type Owner = "requester" | "different_user" | "unclaimed" | "unknown";

export interface MergeIntake {
  kind: string;
  keep: string | null;
  others: string[];
  pairs?: Array<{ keep: string; others: string[] }>;
  suspect_artist_names?: string[];
  requester_owns: Record<string, Owner>;
  user_claim: { asserted_same_person: string | null; asserted_direction: string | null; customer_note: string | null };
  complete: boolean;
}

function str(v: unknown): string {
  return typeof v === "string" ? v.trim() : "";
}

/** An id when a UUID can be read from a profile/track URL or id, else the cleaned ref. */
export function refId(v: unknown): string {
  const s = str(v);
  if (!s) return "";
  const m = s.match(UUID_IN);
  return m ? m[0].toLowerCase() : stripInjectionMarkers(s).slice(0, MAX_REF);
}

function list(v: unknown): string[] {
  return Array.isArray(v) ? v.map(refId).filter(Boolean) : [];
}

function claimText(v: unknown): string | null {
  if (typeof v === "boolean") return v ? "yes" : "no";
  const s = str(v);
  return s ? stripInjectionMarkers(s).replace(/\s+/g, " ").slice(0, MAX_CLAIM) : null;
}

// dedupe_check's DuplicateVerdict.claim_state ("unresolved" -> unknown).
const CLAIM_STATE: Record<string, Owner> = {
  unclaimed: "unclaimed",
  claimed_same_owner: "requester",
  claimed_different_user: "different_user",
};

/** Per-id ownership from dedupe_check's own verdict only; anything else is "unknown". */
function ownership(v: Verdict | null, keep: string | null, others: string[]): Record<string, Owner> {
  const out: Record<string, Owner> = {};
  for (const id of [keep, ...others]) if (id) out[id] = "unknown";
  if (!v || v.owner_undetermined || v.impersonation_flag) return out;
  if (keep && v.owns_survivor && refId(v.survivor_profile_id) === keep) out[keep] = "requester";
  for (const d of v.duplicates) {
    const id = refId(d.profile_id);
    if (!id || !(id in out)) continue;
    const owner = CLAIM_STATE[d.claim_state] ?? "unknown";
    out[id] = owner === "requester" && d.claimed_workspace_count !== 1 ? "unknown" : owner;
  }
  return out;
}

/** The normalized intake record for a merge-type ticket (or null for any other type). */
export function buildMergeIntake(actionType: string, customerProfileId: string | undefined,
                                 details: Record<string, unknown> | undefined,
                                 verdictFor: VerdictLookup = () => null): MergeIntake | null {
  if (!MERGE_KINDS.has(actionType)) return null;
  const d = details ?? {};
  const inputs = (d.merge_judgment_inputs && typeof d.merge_judgment_inputs === "object"
    ? d.merge_judgment_inputs : {}) as Record<string, unknown>;
  const user_claim = {
    asserted_same_person: claimText(inputs.asserted_same_person),
    asserted_direction: claimText(inputs.asserted_direction),
    customer_note: claimText(inputs.customer_note ?? d.customer_note),
  };
  if (actionType === "track-merge") {
    const pairs = (Array.isArray(d.track_merge_pairs) ? d.track_merge_pairs : [])
      .filter((p): p is Record<string, unknown> => !!p && typeof p === "object")
      .map((p) => ({ keep: refId(p.master), others: list(p.duplicates) }))
      .filter((p) => p.keep && p.others.length > 0);
    const flatKeep = refId(d.master_track);
    const flatOthers = list(d.duplicate_tracks);
    if (pairs.length === 0 && flatKeep && flatOthers.length) pairs.push({ keep: flatKeep, others: flatOthers });
    const keep = pairs[0]?.keep ?? null;
    const others = pairs.flatMap((p) => p.others);
    // Tracks are catalog data: who owns them is the customer's profile, recorded as context.
    const owns: Record<string, Owner> = {};
    for (const id of [keep, ...others]) if (id) owns[id] = "unknown";
    return { kind: actionType, keep, others, pairs, requester_owns: owns, user_claim, complete: pairs.length > 0 };
  }
  const keep = refId(d.main_profile_url ?? d.survivor_profile_url ?? d.kept_profile_url) || refId(customerProfileId) || null;
  const others = actionType === "unmerge-request"
    ? list(d.merged_profile_urls ?? (d.merged_profile_url ? [d.merged_profile_url] : []))
    : list(d.duplicate_profile_urls);
  // A suspected wrong merge (credit-removal capability B) names artists, not the merged
  // profile: the executor finds that row in profile_merges, so the record says so.
  const suspects = actionType === "unmerge-request" && Array.isArray(d.suspect_artist_names)
    ? d.suspect_artist_names.map(claimText).filter((x): x is string => !!x) : [];
  return {
    kind: actionType, keep, others,
    ...(suspects.length ? { suspect_artist_names: suspects } : {}),
    requester_owns: ownership(verdictFor(keep, others), keep, others),
    user_claim, complete: !!keep && others.length > 0,
  };
}

/** details with the server-built `merge_intake` (any agent-supplied block replaced). */
export function withMergeIntake(actionType: string, customerProfileId: string | undefined,
                                details: Record<string, unknown> | undefined,
                                verdictFor?: VerdictLookup): Record<string, unknown> | undefined {
  const intake = buildMergeIntake(actionType, customerProfileId, details, verdictFor);
  if (!intake) return details;
  return { ...(details ?? {}), merge_intake: intake };
}

/** The server-built merge_intake carried by a ticket's details, if any. */
export function mergeIntakeOf(details: Record<string, unknown> | undefined): MergeIntake | null {
  const mi = details?.merge_intake;
  return mi && typeof mi === "object" && Array.isArray((mi as MergeIntake).others) ? mi as MergeIntake : null;
}

const lower = (x: string | null | undefined) => (x ?? "").toLowerCase();

function allRefs(mi: MergeIntake): string[] {
  return [mi.keep, ...mi.others, ...(mi.pairs ?? []).flatMap((p) => [p.keep, ...p.others])]
    .map(lower).filter(Boolean);
}

/** The refs naming WHAT to merge or separate. A profile kind's keep is the customer's own
 *  anchor profile (the same for every request in a conversation), so it is not a target. */
export function mergeTargets(mi: MergeIntake): string[] {
  const anchor = mi.kind === "track-merge" ? null : lower(mi.keep);
  return allRefs(mi).filter((r) => r !== anchor);
}

/** Held pair of merge tickets in one conversation that keep different profiles / tracks:
 *  both carry KEEP_CONFLICT_TAG plus KEEP_CONFLICT_WITH<sibling id> until a human reconciles. */
export const KEEP_CONFLICT_TAG = "merge-keep-conflict";
export const KEEP_CONFLICT_WITH = "merge-keep-conflict-with:";
/** A merge ticket whose merge_intake could not be widened to a follow-up's targets: held
 *  (never worked or messaged) like KEEP_CONFLICT_TAG until a human removes the tag. */
export const INTAKE_STALE_TAG = "merge-intake-stale";

function trackKeeps(mi: MergeIntake): Map<string, string> {
  const keepOf = new Map<string, string>();
  for (const p of mi.pairs ?? []) {
    keepOf.set(lower(p.keep), lower(p.keep));
    for (const o of p.others) keepOf.set(lower(o), lower(p.keep));
  }
  return keepOf;
}

/** Both intakes keep the same thing: the same profile (normalized ref), or for track-merge
 *  every track both name sits under the same kept track in each (no reversed or moved pair). */
export function sameMergeKeep(a: MergeIntake, b: MergeIntake): boolean {
  if (a.kind !== "track-merge") return lower(a.keep) === lower(b.keep);
  const keepB = trackKeeps(b);
  return [...trackKeeps(a)].every(([ref, keep]) => !keepB.has(ref) || keepB.get(ref) === keep);
}

/** Two intakes about the same refs: a target of one is a ref of the other. */
export function mergeIntakesOverlap(a: MergeIntake, b: MergeIntake): boolean {
  const refsA = new Set(allRefs(a));
  const refsB = new Set(allRefs(b));
  return mergeTargets(a).some((r) => refsB.has(r)) || mergeTargets(b).some((r) => refsA.has(r));
}

function uniq(xs: Array<string | null | undefined>, except: string | null = null): string[] {
  const seen = new Set<string>(except ? [lower(except)] : []);
  const out: string[] = [];
  for (const x of xs) {
    if (!x || seen.has(lower(x))) continue;
    seen.add(lower(x));
    out.push(x);
  }
  return out;
}

/** The intake of an open ticket after a follow-up about the same request (the same keep):
 *  every ref of both, the newer customer claim where it says something, and per side the
 *  ownership dedupe_check verified ("unknown" when the two verdicts disagree). */
export function unionMergeIntake(a: MergeIntake, b: MergeIntake): MergeIntake {
  const suspects = uniq([...(a.suspect_artist_names ?? []), ...(b.suspect_artist_names ?? [])]);
  let keep: string | null, others: string[], pairs: MergeIntake["pairs"];
  if (a.kind === "track-merge") {
    const byKeep = new Map<string, { keep: string; others: string[] }>();
    for (const p of [...(a.pairs ?? []), ...(b.pairs ?? [])]) {
      const cur = byKeep.get(lower(p.keep));
      byKeep.set(lower(p.keep), { keep: cur?.keep ?? p.keep, others: uniq([...(cur?.others ?? []), ...p.others], p.keep) });
    }
    pairs = [...byKeep.values()];
    keep = pairs[0]?.keep ?? null;
    others = uniq(pairs.flatMap((p) => p.others));
  } else {
    keep = a.keep;
    others = uniq([...a.others, ...b.others], keep);
  }
  const requester_owns: Record<string, Owner> = {};
  for (const id of [keep, ...others]) {
    if (!id) continue;
    const known = new Set([a.requester_owns[id], b.requester_owns[id]].filter((o) => o && o !== "unknown"));
    requester_owns[id] = known.size === 1 ? [...known][0] : "unknown";
  }
  const user_claim = {
    asserted_same_person: b.user_claim.asserted_same_person ?? a.user_claim.asserted_same_person,
    asserted_direction: b.user_claim.asserted_direction ?? a.user_claim.asserted_direction,
    customer_note: b.user_claim.customer_note ?? a.user_claim.customer_note,
  };
  return {
    kind: a.kind, keep, others,
    ...(pairs ? { pairs } : {}),
    ...(suspects.length ? { suspect_artist_names: suspects } : {}),
    requester_owns, user_claim,
    complete: a.kind === "track-merge" ? (pairs ?? []).length > 0 : !!keep && others.length > 0,
  };
}

const AR_OPEN = "---ACTION-REQUEST---\n";
const JSON_ESCAPES = "\"\\/bfnrtu";

// ClickUp stores descriptions as rich text and regenerates markdown on read, escaping
// markdown punctuation (`\_`) that is not a valid JSON escape: drop those backslashes.
function parseActionRequest(block: string): unknown {
  for (const text of [block, block.replace(/\\([\s\S])/g, (m, c: string) => JSON_ESCAPES.includes(c) ? m : c)]) {
    try {
      return JSON.parse(text);
    } catch {
      continue;
    }
  }
  return undefined;
}
const AR_CLOSE = "\n---END-ACTION-REQUEST---";

/** The ticket description with ONLY its ---ACTION-REQUEST--- block's details.merge_intake
 *  replaced (everything else, human edits included, untouched); null when that block is
 *  missing or unreadable. */
export function withActionRequestIntake(markdown: string, intake: MergeIntake): string | null {
  const start = markdown.indexOf(AR_OPEN);
  if (start < 0) return null;
  const from = start + AR_OPEN.length;
  const end = markdown.indexOf(AR_CLOSE, from);
  if (end < 0) return null;
  const ar = parseActionRequest(markdown.slice(from, end));
  if (!ar || typeof ar !== "object" || Array.isArray(ar)) return null;
  const rec = ar as Record<string, unknown>;
  const details = rec.details && typeof rec.details === "object" && !Array.isArray(rec.details)
    ? rec.details as Record<string, unknown> : {};
  const next = { ...rec, details: { ...details, merge_intake: intake } };
  return markdown.slice(0, from) + JSON.stringify(next, null, 2) + markdown.slice(end);
}
