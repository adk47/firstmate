import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { HttpClient } from "../http.js";
import type { RateLimiter } from "../rate-limiter.js";
import type { SessionTicketRegistry } from "../session-ticket-registry.js";
import {
  GROWTH_ACTIONS,
  TIER_SLAS,
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
import { deriveConvId } from "./dedupe-check.js";
import { validateProdigiAddress } from "../order-address.js";

const Parameters = Type.Object({
  actionType: Type.String({ description: "Type of action request. One of: credit-claim, credit-correction, credit-verify, profile-claim, support-general, analytics-followup, order-fulfillment, profile-merge, unmerge-request, bulk-credit-change, profile-update, subscription-refund, data-deletion, dispute, data-export" }),
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
  | { submitted: true; ticket_id: string; sla: string; action_type: string; tier: number }
  | { submitted: true; updated_existing: true; ticket_id: string; sla: string; action_type: string; tier: number }
  | { submitted: false; reason: "rate_limited" }
  | { submitted: false; reason: "queue_busy" }
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

// Tier-2 actions that MUTATE a specific profile and are genuinely unactionable
// without knowing which profile. Gated below (require customerProfileId).
// Deliberately does NOT include tier-1 types — an over-strict gate that blocks
// Caroline from filing would *cause* dropped customers, the exact harm we're
// fixing. profile-merge has its own richer gate above.
const PROFILE_ANCHOR_REQUIRED = new Set(["profile-update", "bulk-credit-change", "unmerge-request"]);

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
}

interface ClickupTaskSummary {
  id: string;
  status?: { status?: string; type?: string };
  date_created?: string;
  tags?: { name?: string }[];
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
  const { clickupIntercomLinkFieldId, intercomWorkspaceId, clickupMusoUrlFieldId, clickupTeamFieldId, sessionTickets } = deps;

  // Restart-proof fallback for the dedupe. Deliberately WIDER than the
  // session registry: it matches any open <7d ticket for the same customer
  // email + action tag, across conversations — a second same-type ask within
  // a week is treated as the same request. Fail-soft — any error means "no
  // existing ticket", never a blocked filing.
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
      return open[0]?.id ?? null;
    } catch (err) {
      console.warn(`[support-tools] create_ticket dedupe lookup failed (creating anyway): ${err}`);
      return null;
    }
  }

  // Registry entries can outlive the ticket they point at (ops closes it
  // mid-conversation). Re-check before appending; fail-open on API errors so
  // a transient 5xx doesn't spawn a duplicate.
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

      if (!(params.actionType in TIER_MAP)) {
        console.warn(`[support-tools] Unknown actionType "${params.actionType}", defaulting to tier 1`);
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

      const contentParams = {
        summary: params.summary, actionType: params.actionType, tier,
        customerEmail: params.customerEmail, customerProfileId: params.customerProfileId,
        details, conversationSummary: params.conversationSummary, sessionId,
      };

      // --- Dedupe: same conversation + same action type → append, don't re-file.
      // (Live 2026-06-10 audit: customers adding one detail produced up to 5
      // duplicate tickets per conversation — see jurakez1/jenarobinson10.)
      let existingId = sessionTickets.get(sessionId, params.actionType, params.customerEmail);
      if (existingId && !(await isTicketStillOpen(existingId))) {
        sessionTickets.invalidate(sessionId, params.actionType, params.customerEmail);
        existingId = null;
      }
      // Cross-conversation fallback. Skipped for profile-merge: the merged-
      // ticket sweep auto-closes those keyed on the ORIGINAL description's
      // profile ids, so appending a different merge request cross-conversation
      // could be closed unexecuted. The lookup GET is metered in its own
      // bucket so a retry-looping session can't hammer ClickUp search.
      if (!existingId && params.actionType !== "profile-merge"
          && rateLimiter.check(sessionId, "create_ticket_lookup", 60, 10).allowed) {
        existingId = await lookupOpenTicket(params.actionType, params.customerEmail);
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
          sessionTickets.record(sessionId, params.actionType, params.customerEmail, existingId);
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
          return ticketResult({ submitted: true, updated_existing: true, ticket_id: existingId, sla, action_type: params.actionType, tier });
        }
        // Comment failed — fall through to creating a fresh ticket (today's
        // status quo); losing the update entirely would be worse than a dup.
        console.warn(`[support-tools] create_ticket follow-up comment failed for ${existingId}, creating a new ticket instead`);
      }

      if (!rateLimiter.check(sessionId, "create_ticket", 60, 2).allowed) {
        return ticketResult({ submitted: false, reason: "rate_limited" });
      }

      const customFields: { id: string; value: string }[] = [
        { id: clickupUserEmailFieldId, value: params.customerEmail },
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

      const body: Record<string, unknown> = {
        name: buildTicketTitle({ actionType: params.actionType, gist, customerEmail: params.customerEmail }),
        markdown_description: buildTicketMarkdown({ ...contentParams, gist, sla, customerName, intercomUrl }),
        status: "to do",
        priority,
        due_date: slaDueDateMs(tier, Date.now()),
        due_date_time: false,
        tags: buildTicketTags({ actionType: params.actionType, tier, details: params.details }),
        custom_fields: customFields,
      };
      if (params.actionType === "profile-merge" && profileMergeAssigneeId) {
        body.assignees = [profileMergeAssigneeId];
      }

      const result = await http.post<{ id: string }>(
        `https://api.clickup.com/api/v2/list/${clickupListId}/task`,
        { headers: { Authorization: clickupApiKey }, body },
      );

      if (!result.ok) {
        return ticketResult({ submitted: false, reason: "queue_busy" });
      }

      sessionTickets.record(sessionId, params.actionType, params.customerEmail, result.data.id);
      return ticketResult({ submitted: true, ticket_id: result.data.id, sla, action_type: params.actionType, tier });
    },
  };
}
