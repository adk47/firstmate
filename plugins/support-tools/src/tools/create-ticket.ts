import { randomUUID } from "node:crypto";
import { mkdir, rename, writeFile } from "node:fs/promises";
import { join } from "node:path";
import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { HttpClient } from "../http.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { MergeTicketEntry, SessionTicketRegistry } from "../session-ticket-registry.js";
import {
  GROWTH_ACTIONS,
  TIER_SLAS,
  customerSlaFor,
  outcomeChannelFor,
  type OutcomeChannel,
  TIER_TO_PRIORITY,
  TIER_MAP,
  getTierForAction,
  buildTicketTitle,
  buildTicketMarkdown,
  buildFollowupComment,
  buildTicketTags,
  escalationTag,
  URGENT_ESCALATION_REASONS,
  slaDueDateMs,
  musoProfileUrl,
  intercomDeeplink,
} from "./ticket-format.js";
import { deriveConvId, type DedupeVerdictStore } from "./dedupe-check.js";
import { markTicketFiled, markTicketId } from "../ticket-success-signal.js";
import { validateProdigiAddress } from "../order-address.js";
import {
  INTAKE_STALE_TAG, KEEP_CONFLICT_TAG, KEEP_CONFLICT_WITH, MERGE_KINDS, mergeIntakeOf, mergeIntakesOverlap, mergeTargets,
  sameMergeKeep, unionMergeIntake,
  withActionRequestIntake, withMergeIntake, type MergeIntake,
} from "./merge-intake.js";

const Parameters = Type.Object({
  actionType: Type.String({
    enum: Object.keys(TIER_MAP),
    description: "Choose the specific requested action: credit-claim for adding a credit, profile-merge or track-merge for merges. Use credit-correction, credit-removal (the customer wants a credit hidden, or says it is not them) or credit-verify for those distinct requests; use support-general only when no specific action applies. ClickUp views route by the resulting action tag.",
  }),
  customerEmail: Type.String({ description: "Customer's email address" }),
  summary: Type.String({ description: "Plain English description of what the customer is requesting" }),
  titleGist: Type.Optional(Type.String({ description: "Short, concrete gist for the ticket title (max 60 chars), e.g. 'Recurring charges since Jan, no account found'. Falls back to the summary when omitted." })),
  customerProfileId: Type.Optional(Type.String({ description: "Customer's Muso profile ID, if known from profile_lookup" })),
  details: Type.Optional(Type.Record(Type.String(), Type.Unknown(), { description: "Additional action-specific details (e.g., track name, credit role). Include customer_name when known — it is rendered next to the email in the ticket header." })),
  conversationSummary: Type.String({ description: "2-3 sentence summary of the conversation context" }),
});

type Params = Static<typeof Parameters>;

// Discriminated union of every shape this tool returns. Centralized so that
// a typo on one branch doesn't slip through; consumers can rely on `reason`
// to differentiate failure modes.
export type CreateTicketResult =
  | { submitted: true; ticket_id: string; sla: string | null; action_type: string; tier: number;
      customer_timing?: string; merge_keep_conflict_flag_failed?: true }
  | { submitted: true; updated_existing: true; ticket_id: string; sla: string | null; action_type: string; tier: number;
      customer_timing?: string; merge_keep_conflict_flag_failed?: true }
  | { submitted: false; reason: "rate_limited" }
  | { submitted: false; reason: "merge_intake_not_updated"; action_type: string; ticket_id: string; hint: string }
  | { submitted: false; reason: "keep_conflict_unflagged"; action_type: string; ticket_ids: string[]; hint: string }
  | { submitted: false; reason: "queue_busy" }
  | { submitted: false; reason: "invalid_action_type"; hint: string }
  | {
      submitted: false;
      reason: "profile_merge_capture_incomplete";
      missing: string[];
      hint: string;
    }
  | {
      submitted: false;
      reason: "capture_incomplete";
      action_type: string;
      missing: string[];
      hint: string;
    };

function ticketResult(r: CreateTicketResult): AgentToolResult<unknown> {
  return textResult(JSON.stringify(r));
}

// What Caroline is told about timing on a successful file. `sla` is the timeframe she may
// quote (once); for credit/claim/merge requests it is null and `customer_timing` says why,
// so the internal tier SLA can never be read back to a customer as a promise.
const NO_TIMEFRAME = "Quote no timeframe: no day count, no business days, no 'soon'";
export const NO_TIMEFRAME_NOTES: Record<OutcomeChannel, string> = {
  conversation: `${NO_TIMEFRAME}. The outcome is posted as a reply in this conversation when it lands.`,
  app_notification: `${NO_TIMEFRAME} (the only timing line allowed is "usually within a day once the step is done"). ` +
    "The claim message reaches the customer in the app and by email, so do not promise a reply in this conversation.",
  conversation_email: `${NO_TIMEFRAME}. Say only that they will hear in this conversation and by email.`,
  erasure: `${NO_TIMEFRAME}. Use the GDPR acknowledgement verbatim (its only timing: "within one month of today" for the ` +
    "written confirmation); a claim is never required; never say deleted.",
};

function customerTiming(actionType: string): { sla: string | null; customer_timing?: string } {
  const sla = customerSlaFor(actionType);
  return sla === null ? { sla, customer_timing: NO_TIMEFRAME_NOTES[outcomeChannelFor(actionType)] } : { sla };
}

// The open merge ticket a new request of the same kind belongs to: one that keeps the same
// profile / track and shares a ref with it (a request naming no targets: the newest with the
// same keep). Overlapping tickets that keep something else are a DIFFERENT request.
function matchMergeTicket(entries: Array<MergeTicketEntry<MergeIntake>>, intake: MergeIntake):
    { hit: MergeTicketEntry<MergeIntake> | null; conflicts: Array<MergeTicketEntry<MergeIntake>> } {
  if (mergeTargets(intake).length === 0) {
    return { hit: entries.find((e) => sameMergeKeep(e.payload, intake)) ?? null, conflicts: [] };
  }
  const overlapping = entries.filter((e) => mergeIntakesOverlap(e.payload, intake));
  return { hit: overlapping.find((e) => sameMergeKeep(e.payload, intake)) ?? null,
           conflicts: overlapping.filter((e) => !sameMergeKeep(e.payload, intake)) };
}

function keepConflictComment(actionType: string, siblingId: string): string {
  const what = actionType === "track-merge" ? "tracks" : "profiles";
  return `**Merge keep conflict** (${actionType}): this conversation also has ticket `
    + `https://app.clickup.com/t/${siblingId}, a merge request that keeps different ${what}. `
    + `Both tickets are held (tag ${KEEP_CONFLICT_TAG}): do not work either one until a human `
    + `reconciles them with the customer: close the ticket you reject and remove `
    + `${KEEP_CONFLICT_TAG} from the one you keep.`;
}

// Tier-2 actions that MUTATE a specific profile and are genuinely unactionable
// without knowing which profile. Gated below (require customerProfileId).
// Deliberately does NOT include tier-1 types — an over-strict gate that blocks
// Caroline from filing would *cause* dropped customers, the exact harm we're
// fixing. profile-merge has its own richer gate above.
const PROFILE_ANCHOR_REQUIRED = new Set(["profile-update", "bulk-credit-change", "unmerge-request"]);
const UUID_RE = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

// A credit-verification ticket remains a valid human-review handoff even when
// it lacks exact request ids. The autonomous UVN under-30 runner is enrolled
// by PROFILE: it resolves the profile's live pending rows from the backend
// itself, so all it needs from the ticket is a UUID profile. Exact `cr_id`s,
// when Caroline does supply them, only narrow that scope, and a `cr_id` that
// is present but not a UUID is a malformed block that must not enroll.
// History: the earlier exact-id gate (UUID cr_id on every pending credit) was
// never satisfied in production — 39 of 40 tickets measured on 2026-09-04
// carried no cr_ids at all — so the runner approved nothing for three weeks.
// Caroline's `recommendation` deliberately does NOT gate eligibility: it is
// customer-influenced pre-screen evidence for the human reviewer. The
// runner's own policy (sub-30, fraud truth-floor, hard-reject rules,
// still-UVN, re-verify before every write) is the gate, so this tag is an
// eligibility marker rather than authorization.
function hasAutomationReadyUvnScope(
  actionType: string,
  customerProfileId: string | undefined,
  details: Record<string, unknown> | undefined,
): boolean {
  if (actionType !== "credit-verify" || !customerProfileId || !UUID_RE.test(customerProfileId)) {
    return false;
  }
  const pending = details?.pending_credits;
  if (pending === undefined || pending === null) return true;
  if (!Array.isArray(pending)) return false;
  return pending.every((item) => {
    if (typeof item !== "object" || item === null) return false;
    const requestId = (item as Record<string, unknown>).cr_id;
    if (requestId === undefined || requestId === null || requestId === "") return true;
    return typeof requestId === "string" && UUID_RE.test(requestId);
  });
}

// A profile merge's "main" profile (this ticket's required field) and its
// "survivor" (the name dedupe_check and the profiles_consolidate tool use) are
// the SAME kept profile. Caroline sometimes captures only `survivor_profile_url`;
// treat it as satisfying `main_profile_url` so an otherwise-complete capture
// isn't bounced as incomplete over which synonym was used (the original
// first-call failure on conv 215474855199857, 2026-06-26). Returns details
// unchanged when main is already set or when neither URL is present (a genuine
// gap the validation gate should report).
function resolveMergeMainUrl(
  details: Record<string, unknown> | undefined,
): Record<string, unknown> | undefined {
  if (!details) return details;
  const main = typeof details.main_profile_url === "string" ? details.main_profile_url.trim() : "";
  if (main) return details;
  const survivor = typeof details.survivor_profile_url === "string" ? details.survivor_profile_url.trim() : "";
  if (!survivor) return details;
  return { ...details, main_profile_url: survivor };
}

// ClickUp "Team" dropdown option ids (list 901000600160). Growth owns
// account/billing/support; Catalog owns the catalog data (credits, profiles,
// tracks, analytics, merges).
const TEAM_OPTION_CATALOG = "da684786-49eb-4306-87c2-30c093d6dc35";
const TEAM_OPTION_GROWTH = "fab5b56c-953f-490f-8eb9-2d33f108114f";

export function teamOptionFor(actionType: string): string {
  return GROWTH_ACTIONS.has(actionType) ? TEAM_OPTION_GROWTH : TEAM_OPTION_CATALOG;
}

// How far back the ClickUp dedupe lookup considers an open ticket "the same
// request". Beyond this, a same-type ask from the same customer is treated as
// a new request.
const DEDUPE_LOOKUP_WINDOW_MS = 7 * 24 * 60 * 60_000;

interface ToolDeps {
  http: HttpClient; rateLimiter: RateLimiter;
  clickupApiKey: string; clickupListId: string;
  clickupProfileIdFieldId: string; clickupUserEmailFieldId: string;
  sessionId: string;
  // Trusted gateway session KEY — carries the Intercom conversation id (via the
  // shared deriveConvId), used only to build the Intercom deeplink. Optional so
  // existing callers/tests that pass only sessionId still typecheck.
  sessionKey?: string;
  profileMergeAssigneeId?: number;
  // dedupe_check's own verdicts (shared instance from index.ts): the only source of
  // merge_intake.requester_owns. Absent = every side "unknown".
  verdictStore?: DedupeVerdictStore;
  // Shared across sessions (instantiated once in index.ts, like rateLimiter)
  // so repeat calls within a conversation find the earlier ticket. Required:
  // a per-tool-instance registry would silently defeat the dedupe.
  sessionTickets: SessionTicketRegistry;
  // Enrichment field ids — each is added to the ticket ONLY when its id is set
  // (wired with real defaults in index.ts). Optional so existing callers/tests
  // that don't pass them are unaffected.
  clickupIntercomLinkFieldId?: string;
  // Intercom app-id for the deeplink (https://app.intercom.com/a/inbox/<app-id>/…);
  // defaulted in index.ts. The live session key no longer carries it.
  intercomWorkspaceId?: string;
  clickupMusoUrlFieldId?: string;
  clickupTeamFieldId?: string;
  // Where a keep conflict that could not be flagged in ClickUp is spooled for
  // scripts/merge-outcome-notify.py (main) to post to #cs_priority. Unset = no spool.
  keepConflictSpoolDir?: string;
}

interface ClickupTaskSummary {
  id: string;
  status?: { status?: string; type?: string };
  date_created?: string;
  tags?: { name?: string }[];
  custom_fields?: { id?: string; value?: unknown }[];
}

// Minimal shape check, not RFC validation: the only job is to refuse to ask
// ClickUp "who matches this email" with "", whitespace or free text (MUS-6588).
const DEDUPE_EMAIL_RE = /^[^\s@]+@[^\s@]+\.[^\s@]+$/;
function isUsableDedupeEmail(e: string): boolean {
  const t = e.trim();
  return t !== "" && DEDUPE_EMAIL_RE.test(t);
}

// "Open" = not done/closed by status TYPE ("to do" and "in progress" are both
// open — a ticket a human picked up must still dedupe). Falls back to the
// literal status string when the type field is absent (test fixtures, older
// API shapes); unknown shapes count as open (fail toward appending, never
// toward duplicating).
function isOpenStatus(s?: { status?: string; type?: string }): boolean {
  if (!s) return true;
  if (s.type) return s.type !== "done" && s.type !== "closed";
  return s.status === "to do" || s.status === "in progress" || s.status === undefined;
}

export function createCreateTicketTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { http, rateLimiter, clickupApiKey, clickupListId, clickupProfileIdFieldId, clickupUserEmailFieldId, sessionId, sessionKey, profileMergeAssigneeId } = deps;
  const { clickupIntercomLinkFieldId, intercomWorkspaceId, clickupMusoUrlFieldId, clickupTeamFieldId, sessionTickets, verdictStore,
    keepConflictSpoolDir } = deps;

  // Restart-proof fallback for the dedupe. Deliberately WIDER than the
  // session registry: it matches any open <7d ticket for the same customer
  // email + action tag, across conversations — a second same-type ask within
  // a week is treated as the same request. Fail-soft — any error means "no
  // existing ticket", never a blocked filing.
  // This is the ONLY cross-conversation lookup in the plugin (class sweep:
  // `git grep custom_fields=` over plugins/support-tools finds only this file).
  // ClickUp's custom_fields filter is not trusted: `value: ""` returned
  // unrelated customers' tasks (MUS-6588), so the newest candidate's email is
  // verified below and an unverifiable candidate is dropped, never appended to.
  async function lookupOpenTicket(actionType: string, customerEmail: string): Promise<string | null> {
    try {
      const customFieldsFilter = JSON.stringify([
        { field_id: clickupUserEmailFieldId, operator: "=", value: customerEmail },
      ]);
      const url =
        `https://api.clickup.com/api/v2/list/${clickupListId}/task` +
        `?include_closed=false` +
        `&date_created_gt=${Date.now() - DEDUPE_LOOKUP_WINDOW_MS}` +
        `&tags%5B%5D=${encodeURIComponent(`action:${actionType}`)}` +
        `&custom_fields=${encodeURIComponent(customFieldsFilter)}`;
      const res = await http.get<{ tasks?: ClickupTaskSummary[] }>(url, { headers: { Authorization: clickupApiKey } });
      if (!res?.ok || !Array.isArray(res.data?.tasks)) return null;
      // Re-filter client-side: the server-side date param is an optimization,
      // not something we trust (live API ignored order_by). Escalation
      // handoff tickets are excluded — appending a normal action request onto
      // a human-takeover record would bury it.
      const cutoff = Date.now() - DEDUPE_LOOKUP_WINDOW_MS;
      const open = res.data.tasks
        .filter((t) =>
          isOpenStatus(t.status) &&
          Number(t.date_created) >= cutoff &&
          !t.tags?.some((tag) => tag.name === "intercom-auto-handoff"))
        .sort((a, b) => Number(b.date_created) - Number(a.date_created));
      const candidate = open[0];
      if (!candidate) return null;
      return (await candidateMatchesEmail(candidate, customerEmail)) ? candidate.id : null;
    } catch (err) {
      console.warn(`[support-tools] create_ticket dedupe lookup failed (creating anyway): ${err}`);
      return null;
    }
  }

  // Verify-or-reject: read the email custom field from the list payload, or
  // (when ClickUp omits custom_fields there) from one single-task GET. Cannot
  // read it, or it differs => not our customer's ticket.
  async function candidateMatchesEmail(task: ClickupTaskSummary, customerEmail: string): Promise<boolean> {
    const emailOf = (t: ClickupTaskSummary) => t.custom_fields?.find((f) => f.id === clickupUserEmailFieldId)?.value;
    let value = emailOf(task);
    if (value === undefined) {
      const res = await http.get<ClickupTaskSummary>(
        `https://api.clickup.com/api/v2/task/${task.id}`,
        { headers: { Authorization: clickupApiKey } },
      );
      if (!res?.ok || !res.data) return false;
      value = emailOf(res.data);
    }
    return typeof value === "string" && value.trim().toLowerCase() === customerEmail.toLowerCase();
  }

  // One ClickUp write, retried once. False when neither attempt landed.
  async function postTwice(url: string, body: unknown): Promise<boolean> {
    for (let attempt = 0; attempt < 2; attempt++) {
      const res = await http.post(url, { headers: { Authorization: clickupApiKey }, body }).catch(() => null);
      if (res?.ok) return true;
    }
    return false;
  }
  const tagUrl = (id: string, name: string) =>
    `https://api.clickup.com/api/v2/task/${id}/tag/${encodeURIComponent(name)}`;

  async function untagTwice(id: string, name: string): Promise<boolean> {
    for (let attempt = 0; attempt < 2; attempt++) {
      const res = await http.delete?.(tagUrl(id, name), { headers: { Authorization: clickupApiKey } }).catch(() => null);
      if (res?.ok) return true;
    }
    return false;
  }

  // A keep conflict ClickUp could not hold: one record (ids only, no customer text) for
  // scripts/merge-outcome-notify.py on main to post to #cs_priority.
  async function spoolUnflagged(record: Record<string, unknown>): Promise<boolean> {
    if (!keepConflictSpoolDir) return false;
    try {
      await mkdir(keepConflictSpoolDir, { recursive: true });
      const name = `${Date.now()}-${randomUUID()}`;
      const tmp = join(keepConflictSpoolDir, `.${name}.tmp`);
      await writeFile(tmp, JSON.stringify(record));
      await rename(tmp, join(keepConflictSpoolDir, `${name}.json`));
      return true;
    } catch {
      return false;
    }
  }

  // Widen an open merge ticket's merge_intake in its LIVE description (only the
  // ---ACTION-REQUEST--- block changes), read and written again once. False when it could not be written.
  async function writeMergeIntake(ticketId: string, intake: MergeIntake): Promise<boolean> {
    for (let attempt = 0; attempt < 2; attempt++) {
      const live = await http.get<{ markdown_description?: unknown }>(
        `https://api.clickup.com/api/v2/task/${ticketId}?include_markdown_description=true`,
        { headers: { Authorization: clickupApiKey } },
      ).catch(() => null);
      const markdown = live?.ok ? live.data?.markdown_description : undefined;
      const next = typeof markdown === "string" ? withActionRequestIntake(markdown, intake) : null;
      if (!next) continue;
      const put = await http.put(
        `https://api.clickup.com/api/v2/task/${ticketId}`,
        { headers: { Authorization: clickupApiKey }, body: { markdown_content: next } },
      ).catch(() => null);
      if (put?.ok) return true;
    }
    return false;
  }

  // Registry entries can outlive the ticket they point at (ops closes it
  // mid-conversation). Re-check before appending; fail-open on API errors so
  // a transient 5xx doesn't spawn a duplicate.
  // An overlapping ticket that keeps something different, as ClickUp has it now: open, and
  // already held by merge-keep-conflict (null = unreadable: open; tagged, but never untagged).
  async function conflictState(ticketId: string): Promise<{ open: boolean; held: boolean | null; tags: string[] }> {
    try {
      const res = await http.get<ClickupTaskSummary>(
        `https://api.clickup.com/api/v2/task/${ticketId}`,
        { headers: { Authorization: clickupApiKey } },
      );
      if (!res?.ok || !res.data) return { open: true, held: null, tags: [] };
      const names = (res.data.tags ?? []).map((t) => String(t.name ?? "").toLowerCase());
      return { open: isOpenStatus(res.data.status), held: names.includes(KEEP_CONFLICT_TAG), tags: names };
    } catch {
      return { open: true, held: null, tags: [] };
    }
  }

  // Hold two open tickets as a keep-conflict pair: each tagged merge-keep-conflict and
  // merge-keep-conflict-with:<other>, and a comment on each naming the other (each write
  // retried once). held: both merge-keep-conflict tags landed; complete: every write did;
  // tagged: the tickets whose merge-keep-conflict tag landed.
  async function holdPair(actionType: string, a: string, b: string):
    Promise<{ held: boolean; complete: boolean; tagged: string[] }> {
    const comment = (on: string, sibling: string) => postTwice(`https://api.clickup.com/api/v2/task/${on}/comment`,
      { comment_text: keepConflictComment(actionType, sibling), notify_all: false });
    const ok = await Promise.all([
      postTwice(tagUrl(a, KEEP_CONFLICT_TAG), {}), postTwice(tagUrl(b, KEEP_CONFLICT_TAG), {}),
      postTwice(tagUrl(a, `${KEEP_CONFLICT_WITH}${b}`), {}), postTwice(tagUrl(b, `${KEEP_CONFLICT_WITH}${a}`), {}),
      comment(a, b), comment(b, a),
    ]);
    return { held: ok[0] && ok[1], complete: !ok.includes(false), tagged: [a, b].filter((_, i) => ok[i]) };
  }

  // A keep conflict that could not be held in ClickUp: nothing was filed. Spool it for
  // #cs_priority (main notifier) and tell Caroline to hand off. leftHeld: tickets this call
  // tagged merge-keep-conflict and did not (or could not) release, left held for a human to check.
  async function unflagged(actionType: string, ticketIds: string[], convId: string | null | undefined,
                           leftHeld: string[] = []): Promise<AgentToolResult<unknown>> {
    const spooled = await spoolUnflagged({ ticket_ids: ticketIds, conversation_id: convId ?? null,
      action_type: actionType, ...(leftHeld.length ? { left_held: leftHeld } : {}),
      at: new Date().toISOString() });
    if (!spooled) {
      console.error(`[support-tools] ALERT create_ticket keep conflict with ${ticketIds.join(", ")} `
        + `(conversation ${convId ?? "?"}) could NOT be held in ClickUp NOR spooled for #cs_priority; `
        + "the merge request was not filed" + (leftHeld.length ? ` and ${leftHeld.join(", ")} stay held` : ""));
    }
    return ticketResult({ submitted: false, reason: "keep_conflict_unflagged", action_type: actionType,
      ticket_ids: ticketIds,
      hint: "This merge request keeps a different profile or track than an open ticket in this conversation, "
        + "and it could not be held for review, so it was NOT filed."
        + " Do not tell the customer the team was alerted and give no timing; hand the conversation to a human "
        + "through the Human Handoff route." });
  }

  async function isTicketStillOpen(ticketId: string): Promise<boolean> {
    try {
      const res = await http.get<ClickupTaskSummary>(
        `https://api.clickup.com/api/v2/task/${ticketId}`,
        { headers: { Authorization: clickupApiKey } },
      );
      if (!res?.ok) return true;
      return isOpenStatus(res.data?.status);
    } catch {
      return true;
    }
  }

  return {
    name: "create_ticket",
    label: "Create Support Ticket",
    description: "Create a support ticket in the team's task system for customer requests that require human action (credit claims, profile merges, analytics followups, refunds, data deletion, etc.). When the same request already has a ticket in this conversation, the new information is appended to it instead of opening a duplicate.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      // Normalize once: "empty" has a single shape everywhere below.
      const customerEmail = params.customerEmail.trim();
      // Action-specific detail enrichment, normalized ONCE up front so the
      // validation gate below and the rendered ticket read the same object.
      let details = params.details;

      // Validate BEFORE the rate-limit check. A malformed profile-merge call
      // shouldn't consume the 2-per-60s budget — the agent will retry once it
      // gets the missing fields from the customer, and that retry should be
      // unaffected by previous validation failures.
      if (params.actionType === "profile-merge") {
        details = resolveMergeMainUrl(details);
        const d = details ?? {};
        const missing: string[] = [];
        if (!params.customerProfileId || !params.customerProfileId.trim()) {
          missing.push("customerProfileId");
        }
        const mainUrl = typeof d.main_profile_url === "string" ? d.main_profile_url.trim() : "";
        if (!mainUrl) missing.push("details.main_profile_url");
        const dupUrls = Array.isArray(d.duplicate_profile_urls)
          ? d.duplicate_profile_urls.filter((u): u is string => typeof u === "string" && u.trim().length > 0)
          : [];
        if (dupUrls.length === 0) missing.push("details.duplicate_profile_urls");
        if (missing.length > 0) {
          return ticketResult({
            submitted: false,
            reason: "profile_merge_capture_incomplete",
            missing,
            hint: "Profile-merge tickets need customer_profile_id, details.main_profile_url, and details.duplicate_profile_urls[]. Ask the customer for both the profile they want to keep AND each duplicate URL before retrying.",
          });
        }
      }

      // Track-merge capture gate. Ops's POST /admin/tracks/merge needs to know
      // which track to KEEP and which duplicate(s) to fold into it — a ticket
      // without that is silently un-actionable (the same null-fields failure that
      // motivated the profile-merge gate). Accept either the multi-merge shape
      // (details.track_merge_pairs[{master, duplicates[]}], for the 7-pair case)
      // or the single-merge flat shape (details.master_track + duplicate_tracks[]).
      // NOT customerProfileId-anchored: track merges are catalog data keyed on
      // track ids, not a profile. Runs before the rate-limit check so a retry
      // after the customer supplies the tracks isn't penalised.
      if (params.actionType === "track-merge") {
        const d = details ?? {};
        // A pair is actionable only if it names a non-empty string master AND at least
        // one non-empty string duplicate. A non-empty array of malformed pairs
        // (`[{}]`, `{master:"A", duplicates:[]}`, non-string entries) must NOT pass —
        // that would file the same un-actionable ticket this gate exists to prevent.
        const pairIsValid = (p: unknown): boolean => {
          if (typeof p !== "object" || p === null) return false;
          const pair = p as Record<string, unknown>;
          const master = typeof pair.master === "string" ? pair.master.trim() : "";
          const dups = Array.isArray(pair.duplicates)
            ? pair.duplicates.filter((x): x is string => typeof x === "string" && x.trim().length > 0)
            : [];
          return master.length > 0 && dups.length > 0;
        };
        const rawPairs = Array.isArray(d.track_merge_pairs) ? d.track_merge_pairs : [];
        const havePairs = rawPairs.length > 0 && rawPairs.every(pairIsValid);
        const master = typeof d.master_track === "string" ? d.master_track.trim() : "";
        const dupTracks = Array.isArray(d.duplicate_tracks)
          ? d.duplicate_tracks.filter((t): t is string => typeof t === "string" && t.trim().length > 0)
          : [];
        const haveFlat = master.length > 0 && dupTracks.length > 0;
        if (!havePairs && !haveFlat) {
          return ticketResult({
            submitted: false,
            reason: "capture_incomplete",
            action_type: "track-merge",
            missing: ["details.track_merge_pairs[] (or details.master_track + details.duplicate_tracks[])"],
            hint: "Track-merge tickets need which track to KEEP and which duplicate track(s) to fold into it. Capture the customer's stated track URLs/ids — as details.track_merge_pairs[{master, duplicates[]}] for multiple merges, or details.master_track + details.duplicate_tracks[] for a single one — before retrying.",
          });
        }
      }

      // Unmerge capture gate (Fable ops-takeover §4 step 1): the executor reverses a
      // `profile_merges` row, so it needs what should come back out (the kept side is
      // customerProfileId, required by PROFILE_ANCHOR_REQUIRED below).
      if (params.actionType === "unmerge-request") {
        const d = details ?? {};
        // A customer asking to undo a merge names the profile to separate; the
        // credit-removal skill's wrong-merge detection (capability B) names the suspect
        // artist(s) instead, and the executor finds the merge row from profile_merges.
        const merged = (Array.isArray(d.merged_profile_urls) ? d.merged_profile_urls : [d.merged_profile_url])
          .some((u) => typeof u === "string" && u.trim().length > 0)
          || (Array.isArray(d.suspect_artist_names) && d.suspect_artist_names.some((n) => typeof n === "string" && n.trim()));
        if (!merged) {
          return ticketResult({
            submitted: false,
            reason: "capture_incomplete",
            action_type: "unmerge-request",
            missing: ["details.merged_profile_urls[] (or details.suspect_artist_names[])"],
            hint: "Unmerge tickets need what should be separated out again: each profile that was merged into the customer's profile (name or URL as they gave it), or for a suspected wrong merge the suspect artist name(s). Ask for it before retrying.",
          });
        }
      }

      // Profile-mutating tier-2 actions can't be actioned without knowing WHICH
      // profile. Require customerProfileId for them (light gate — tier-1 stays
      // ungated so Caroline can always file). Runs before the rate-limit check
      // so a retry after capturing the id isn't penalised.
      if (PROFILE_ANCHOR_REQUIRED.has(params.actionType)) {
        if (!params.customerProfileId || !params.customerProfileId.trim()) {
          return ticketResult({
            submitted: false,
            reason: "capture_incomplete",
            action_type: params.actionType,
            missing: ["customerProfileId"],
            hint: `${params.actionType} needs the customer's Muso profile id (which profile to act on). Run profile_lookup or ask the customer for their profile URL before retrying.`,
          });
        }
      }

      if (!Object.prototype.hasOwnProperty.call(TIER_MAP, params.actionType)) {
        return ticketResult({
          submitted: false,
          reason: "invalid_action_type",
          hint: "Choose a supported actionType. Use credit-claim for adding credits, profile-merge or track-merge for merges; do not use support-general for these requests.",
        });
      }

      const tier = getTierForAction(params.actionType);
      const priority = TIER_TO_PRIORITY[tier];
      const sla = TIER_SLAS[tier];

      // order-fulfillment tickets carry a proposed corrected shipping address.
      // Stamp a deterministic Prodigi-rules validation (<=40 chars/line, required
      // fields, "name looks like a street" tell) onto the ticket so ops can trust
      // the address without re-counting. NON-BLOCKING — never gates filing
      // (tier-1 must always be fileable; see PROFILE_ANCHOR_REQUIRED rationale).
      if (
        params.actionType === "order-fulfillment" &&
        details?.proposed_corrected_address &&
        typeof details.proposed_corrected_address === "object"
      ) {
        details = {
          ...details,
          address_validation: validateProdigiAddress(details.proposed_corrected_address),
        };
      }

      // Normalized merge intake for the executor (ids, server-verified ownership per
      // side, the customer's own claim); replaces any agent-supplied merge_intake.
      details = withMergeIntake(params.actionType, params.customerProfileId, details,
        (keep, others) => verdictStore?.get(deriveConvId(sessionKey), keep, others) ?? null);

      const contentParams = {
        summary: params.summary, actionType: params.actionType, tier,
        customerEmail: customerEmail, customerProfileId: params.customerProfileId,
        details, conversationSummary: params.conversationSummary, sessionId,
      };

      // --- Dedupe: same conversation + same action type → append, don't re-file.
      // (Live 2026-06-10 audit: customers adding one detail produced up to 5
      // duplicate tickets per conversation — see jurakez1/jenarobinson10.)
      // Merge kinds match per ticket: a request keeping the same profile / track and sharing a
      // ref with an open ticket appends to it and widens that ticket's merge_intake to the
      // union (the executor works from the description); any other files its own ticket, and
      // one that overlaps a ticket keeping something else is held with it (merge-keep-conflict).
      const mergeIntake = MERGE_KINDS.has(params.actionType) ? mergeIntakeOf(details) : null;
      const mergeMatch = mergeIntake
        ? matchMergeTicket(sessionTickets.merges<MergeIntake>(sessionId, params.actionType, customerEmail),
                           mergeIntake)
        : null;
      let mergeHit = mergeMatch?.hit ?? null;
      let existingId = mergeIntake ? mergeHit?.ticketId ?? null
        : sessionTickets.get(sessionId, params.actionType, customerEmail);
      if (existingId && !(await isTicketStillOpen(existingId))) {
        if (mergeIntake) sessionTickets.invalidateMerge(sessionId, params.actionType, customerEmail, existingId);
        else sessionTickets.invalidate(sessionId, params.actionType, customerEmail);
        existingId = null;
        mergeHit = null;
      }
      // Cross-conversation fallback. Skipped for every merge kind (profile-merge,
      // unmerge-request, track-merge): those are worked and closed keyed on the
      // ORIGINAL description's ids (merge_intake), so appending a DIFFERENT merge
      // request (a distinct track/profile set) cross-conversation could be closed
      // unexecuted. Also
      // skipped for rights_holder: the lookup keys on (actionType, email) only,
      // never on content, so a label/publisher/PRO/law firm mailing about a
      // SECOND matter would be appended to the first matter's open record and
      // lost when the sweep closes it on the first. Rights-holder mail always
      // opens its own record (in-session follow-ups above still append). The
      // lookup GET is metered in its own bucket so a retry-looping session can't
      // hammer ClickUp search.
      if (!existingId && !MERGE_KINDS.has(params.actionType)
          && params.details?.escalation_reason !== "rights_holder"
          && isUsableDedupeEmail(customerEmail)
          && rateLimiter.check(sessionId, "create_ticket_lookup", 60, 10).allowed) {
        existingId = await lookupOpenTicket(params.actionType, customerEmail);
      }
      if (existingId) {
        // Follow-ups get their own (more generous) budget — appending info is
        // cheap and must not eat the 2-per-session create allowance.
        if (!rateLimiter.check(sessionId, "create_ticket_followup", 60, 5).allowed) {
          return ticketResult({ submitted: false, reason: "rate_limited" });
        }
        const comment = await http.post<{ id: string }>(
          `https://api.clickup.com/api/v2/task/${existingId}/comment`,
          {
            headers: { Authorization: clickupApiKey },
            body: { comment_text: buildFollowupComment(contentParams), notify_all: false },
          },
        );
        if (comment?.ok) {
          let appendConflictFlagFailed = false;
          if (mergeIntake && mergeHit) {
            const intake = unionMergeIntake(mergeHit.payload, mergeIntake);
            // The executor works the ticket from its description's merge_intake, so a follow-up
            // only counts as appended once that intake names the new targets too. Every keep
            // conflict the widened intake creates is held BEFORE the intake is widened, so a
            // widened ticket that is not held never exists.
            const others = sessionTickets.merges<MergeIntake>(sessionId, params.actionType, customerEmail)
              .filter((e) => e.ticketId !== existingId);
            const pairIds: string[] = [];
            const tagged = new Set<string>();
            let unheld = false;
            for (const c of matchMergeTicket(others, intake).conflicts) {
              const state = await conflictState(c.ticketId);
              if (!state.open) {
                sessionTickets.invalidateMerge(sessionId, params.actionType, customerEmail, c.ticketId);
                continue;
              }
              if (state.held && state.tags.includes(`${KEEP_CONFLICT_WITH}${existingId}`.toLowerCase())) continue;
              pairIds.push(c.ticketId);
              const hold = await holdPair(params.actionType, existingId, c.ticketId);
              hold.tagged.forEach((id) => tagged.add(id));
              if (!hold.held) unheld = true;
              else if (!hold.complete) {
                appendConflictFlagFailed = true;
                console.error(`[support-tools] ALERT create_ticket ${KEEP_CONFLICT_TAG} pairing incomplete: widened `
                  + `ticket ${existingId} and ${c.ticketId} are held but not every sibling tag / comment landed`);
              }
            }
            // A hold that did not land (or one this call placed for an intake it then could not
            // write) leaves the intake as it was and names every tag it did place for a human.
            const unfiled = () => unflagged(params.actionType, [existingId, ...pairIds], deriveConvId(sessionKey),
              [...tagged]);
            if (unheld) return unfiled();
            if (!(await writeMergeIntake(existingId, intake))) {
              if (tagged.size) return unfiled();
              const held = await postTwice(tagUrl(existingId, INTAKE_STALE_TAG), {});
              const spooled = await spoolUnflagged({ ticket_ids: [existingId], intake_unwritten: true, held,
                conversation_id: deriveConvId(sessionKey) ?? null, action_type: params.actionType,
                at: new Date().toISOString() });
              if (!spooled) {
                console.error(`[support-tools] ALERT create_ticket merge_intake union not written to ${existingId} `
                  + `(${held ? `held: ${INTAKE_STALE_TAG}` : "NOT held"}) and could NOT be spooled for #cs_priority`);
              }
              return ticketResult({ submitted: false, reason: "merge_intake_not_updated",
                action_type: params.actionType, ticket_id: existingId,
                hint: "The new profile or track could not be added to the open merge ticket, so it would not be "
                  + "processed. Do not re-file and do not tell the customer it was added; give no timing. Hand the "
                  + "conversation to a human through the Human Handoff route." });
            }
            sessionTickets.recordMerge<MergeIntake>(sessionId, params.actionType, customerEmail, existingId, intake);
          } else if (!mergeIntake) {
            sessionTickets.record(sessionId, params.actionType, customerEmail, existingId);
          }
          // Signal the intercom false-handoff-claim guard that a ticket really landed
          // for this conversation, so an "I've flagged this for the team" reply is
          // allowed through instead of being rewritten to the honest fallback.
          const followupConvId = deriveConvId(sessionKey);
          markTicketFiled(followupConvId);
          // MUS-1516: also record WHICH id, so the guard's reference-id check
          // can tell a real quoted id from one this conversation never filed.
          markTicketId(followupConvId, existingId);
          // Escalation follow-up (e.g. customer already past the promised
          // SLA): give it teeth — tag the ticket so the overdue sweep groups
          // it, and bump urgent reasons to ClickUp priority 1. Both
          // best-effort: the comment already landed, so a tag/priority hiccup
          // must not regress the customer-facing result.
          const escTag = escalationTag(params.details);
          if (escTag) {
            const tagged = await http.post(
              `https://api.clickup.com/api/v2/task/${existingId}/tag/${encodeURIComponent(escTag)}`,
              { headers: { Authorization: clickupApiKey }, body: {} },
            );
            if (!tagged?.ok) console.warn(`[support-tools] create_ticket escalation tag failed for ${existingId} (${escTag})`);
            const reason = params.details?.escalation_reason;
            if (typeof reason === "string" && URGENT_ESCALATION_REASONS.has(reason)) {
              const bumped = await http.put(
                `https://api.clickup.com/api/v2/task/${existingId}`,
                { headers: { Authorization: clickupApiKey }, body: { priority: 1 } },
              );
              if (!bumped?.ok) console.warn(`[support-tools] create_ticket priority bump failed for ${existingId}`);
            }
          }
          return ticketResult({ submitted: true, updated_existing: true, ticket_id: existingId,
            ...customerTiming(params.actionType), action_type: params.actionType, tier,
            ...(appendConflictFlagFailed ? { merge_keep_conflict_flag_failed: true as const } : {}) });
        }
        // Comment failed — fall through to creating a fresh ticket (today's
        // status quo); losing the update entirely would be worse than a dup.
        console.warn(`[support-tools] create_ticket follow-up comment failed for ${existingId}, creating a new ticket instead`);
      }

      if (!rateLimiter.check(sessionId, "create_ticket", 60, 2).allowed) {
        return ticketResult({ submitted: false, reason: "rate_limited" });
      }

      const customFields: { id: string; value: string }[] = [
        { id: clickupUserEmailFieldId, value: customerEmail },
      ];
      if (params.customerProfileId) {
        customFields.push({ id: clickupProfileIdFieldId, value: params.customerProfileId });
      }

      // --- Enrichment (each field added only when its id is configured) ---
      // Intercom Link: the keystone that lets a resolved ticket be mapped back
      // to its conversation. convId from the trusted gateway session key
      // (deriveConvId, shared with dedupe_check); app-id from the configured
      // default. Best-effort — absent for a non-Intercom / unparseable key, and
      // never blocks creation.
      const convId = deriveConvId(sessionKey);
      const intercomUrl = convId && intercomWorkspaceId
        ? intercomDeeplink(intercomWorkspaceId, convId)
        : undefined;
      if (clickupIntercomLinkFieldId && intercomUrl) {
        customFields.push({ id: clickupIntercomLinkFieldId, value: intercomUrl });
      }
      if (clickupMusoUrlFieldId && params.customerProfileId) {
        customFields.push({ id: clickupMusoUrlFieldId, value: musoProfileUrl(params.customerProfileId) });
      }
      if (clickupTeamFieldId) {
        customFields.push({ id: clickupTeamFieldId, value: teamOptionFor(params.actionType) });
      }

      const gist = params.titleGist?.trim() || params.summary;
      const customerName =
        typeof params.details?.customer_name === "string" ? params.details.customer_name : undefined;
      const tags = buildTicketTags({ actionType: params.actionType, tier, details });
      // Merge-type tickets: the executor's queue filter (details.merge_intake holds the record).
      // Added here, not in ticket-format.ts, which is a byte-identical twin of the intercom plugin's.
      if (MERGE_KINDS.has(params.actionType)) tags.push(`merge-kind:${params.actionType}`);
      if (hasAutomationReadyUvnScope(params.actionType, params.customerProfileId, details)) {
        tags.push("automation:uvn-under30");
      }

      const body: Record<string, unknown> = {
        name: buildTicketTitle({ actionType: params.actionType, gist, customerEmail }),
        markdown_description: buildTicketMarkdown({ ...contentParams, gist, sla, customerName, intercomUrl }),
        status: "to do",
        priority,
        due_date: slaDueDateMs(tier, Date.now()),
        due_date_time: false,
        tags,
        custom_fields: customFields,
      };
      if (params.actionType === "profile-merge" && profileMergeAssigneeId) {
        body.assignees = [profileMergeAssigneeId];
      }

      // A keep conflict is held BEFORE the new ticket exists: each open ticket it conflicts
      // with gets merge-keep-conflict (retried once), and the new ticket is created already
      // carrying merge-keep-conflict + merge-keep-conflict-with:<each>. If an open ticket
      // cannot be tagged, nothing is filed: the record is spooled for #cs_priority instead.
      // Only tags this call adds to a ticket it read as unheld are ever rolled back: a ticket
      // already held, or one whose state could not be read, keeps its hold (spooled for a human
      // to check). A ticket whose rollback cannot land is spooled as left held, the same way.
      const conflictIds: string[] = [];
      const alreadyHeld = new Set<string>();
      const unreadable = new Set<string>();
      for (const c of mergeMatch?.conflicts ?? []) {
        const state = await conflictState(c.ticketId);
        if (!state.open) {
          sessionTickets.invalidateMerge(sessionId, params.actionType, customerEmail, c.ticketId);
          continue;
        }
        conflictIds.push(c.ticketId);
        if (state.held === true) alreadyHeld.add(c.ticketId);
        if (state.held === null) unreadable.add(c.ticketId);
      }
      // leftHeld: tickets this call tagged and leaves held (state unreadable, or rollback failed).
      const leftHeld: string[] = [];
      const preTagged: string[] = [];
      const rollBack = async () => {
        for (const id of preTagged) {
          if (!(await untagTwice(id, KEEP_CONFLICT_TAG))) leftHeld.push(id);
        }
      };
      for (const id of conflictIds) {
        if (alreadyHeld.has(id)) continue;
        if (!(await postTwice(tagUrl(id, KEEP_CONFLICT_TAG), {}))) {
          await rollBack();
          return unflagged(params.actionType, conflictIds, convId, leftHeld);
        }
        if (unreadable.has(id)) leftHeld.push(id);
        else preTagged.push(id);
      }
      if (conflictIds.length) {
        body.tags = [...tags, KEEP_CONFLICT_TAG, ...conflictIds.map((id) => `${KEEP_CONFLICT_WITH}${id}`)];
      }

      const result = await http.post<{ id: string }>(
        `https://api.clickup.com/api/v2/list/${clickupListId}/task`,
        { headers: { Authorization: clickupApiKey }, body },
      );

      if (!result.ok) {
        await rollBack();
        if (leftHeld.length) return unflagged(params.actionType, conflictIds, convId, leftHeld);
        return ticketResult({ submitted: false, reason: "queue_busy" });
      }

      if (mergeIntake) {
        sessionTickets.recordMerge<MergeIntake>(sessionId, params.actionType, customerEmail, result.data.id,
          mergeIntake);
      } else {
        sessionTickets.record(sessionId, params.actionType, customerEmail, result.data.id);
      }
      // Signal the intercom false-handoff-claim guard that a ticket really landed for
      // this conversation (mirrors the follow-up-append path above).
      markTicketFiled(convId);
      // MUS-1516: also record WHICH id (reuses the `convId` already derived above
      // for the Intercom deeplink), so the guard's reference-id check can tell a
      // real quoted id from one this conversation never filed.
      markTicketId(convId, result.data.id);
      let conflictFlagFailed = false;
      for (const id of conflictIds) {
        const comment = (on: string, sibling: string) => postTwice(`https://api.clickup.com/api/v2/task/${on}/comment`,
          { comment_text: keepConflictComment(params.actionType, sibling), notify_all: false });
        const ok = await Promise.all([postTwice(tagUrl(id, `${KEEP_CONFLICT_WITH}${result.data.id}`), {}),
          comment(id, result.data.id), comment(result.data.id, id)]);
        if (ok.includes(false)) conflictFlagFailed = true;
      }
      if (conflictFlagFailed) {
        console.error(`[support-tools] ALERT create_ticket ${KEEP_CONFLICT_TAG} pairing incomplete: ticket ${result.data.id} `
          + `and ${conflictIds.join(", ")} are held but not every sibling tag / comment landed`);
      }
      return ticketResult({ submitted: true, ticket_id: result.data.id, ...customerTiming(params.actionType),
        action_type: params.actionType, tier,
        ...(conflictFlagFailed ? { merge_keep_conflict_flag_failed: true as const } : {}) });
    },
  };
}
