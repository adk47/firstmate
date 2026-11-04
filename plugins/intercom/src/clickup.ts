import type { CreateTicketParams, TicketResult } from "./escalation-action.js";
import type { IntercomAccountConfig } from "./types.js";
import { buildSessionKey } from "./session-key.js";
import {
  TIER_SLAS,
  TIER_TO_PRIORITY,
  getTierForAction,
  buildTicketTitle,
  buildTicketMarkdown,
  buildTicketTags,
  slaDueDateMs,
  intercomDeeplink,
} from "./ticket-format.js";

type ClickupCfg = NonNullable<IntercomAccountConfig["clickup"]>;

interface CreateClickupTicketDeps {
  cfg: ClickupCfg;
  fetchImpl?: typeof fetch;
  log?: { error: (msg: string) => void };
}

// NOTE: this path deliberately does NOT run the open-ticket dedupe that
// create_ticket (support-tools) runs. Escalation fires at most once per
// conversation (escalationFiredAt gate) and its ticket doubles as the
// human-handoff record referenced by the Slack alert — it must always exist,
// even if Caroline already filed a same-type request.
//
// That "at most once" premise is load-bearing HERE — with no dedupe of its own,
// a second call to this function is a second ticket on one conversation, which
// is what a duplicate Conversation-link group in ClickUp looks like. The gate
// alone does not guarantee it: executeEscalation ROLLS THE GATE BACK when the
// farewell and the Slack ping both fail, so the conversation can reach this path
// twice. What actually keeps the premise true is `state.escalationTicketId`
// (escalation-action.ts Step 2), which survives that rollback and makes the retry
// reuse the existing ticket. Do not remove it without adding real dedupe here.
export async function createClickupTicket(
  deps: CreateClickupTicketDeps,
  params: CreateTicketParams,
): Promise<TicketResult> {
  const { cfg, log } = deps;
  const fetchImpl = deps.fetchImpl ?? fetch;

  const tier = getTierForAction(params.actionType);
  const sla = TIER_SLAS[tier];
  // ClickUp VALIDATES email-typed custom fields and 400s the whole task on a
  // non-address value — including the "unknown@unknown" placeholder the
  // escalation path substitutes when no accountEmail is on file (proven live
  // 2026-07-13: 3 of the 58 OAUTH_019 backfill tickets failed exactly this
  // way). Omit the field instead; the markdown body still carries the value.
  const customFields: { id: string; value: string }[] = [];
  if (params.customerEmail && params.customerEmail !== "unknown@unknown") {
    customFields.push({ id: cfg.userEmailFieldId, value: params.customerEmail });
  }
  if (params.customerProfileId) {
    customFields.push({ id: cfg.profileIdFieldId, value: params.customerProfileId });
  }

  // Title subject: the customer's one-line ask when the caller supplies one, so
  // the title reads "[support] Credits missing on 3 tracks — email" instead of
  // "[support] Escalation: turn_count_cap — email". A reason code is not a topic.
  const gist = params.gistSubject?.trim() ? params.gistSubject : `Escalation: ${params.summary}`;

  try {
    // Inside the try: buildSessionKey throws on empty/oversized ids, and this
    // function's contract is "never throws, always returns a TicketResult".
    // Same session-key shape as Caroline's tickets so ops automation parses
    // ONE cs_session_id format across the whole list.
    const contentParams = {
      summary: params.summary,
      actionType: params.actionType,
      tier,
      customerEmail: params.customerEmail,
      customerProfileId: params.customerProfileId,
      // The escalation path's machine-readable hand-off facts. Without this the
      // ---ACTION-REQUEST--- block carried `details: {}` on every ticket, so the
      // ops lanes could not read the customer's question or the reason the
      // hand-off fired (see buildEscalationDetails in escalation-action.ts).
      details: params.details,
      conversationSummary: params.conversationSummary,
      sessionId: buildSessionKey(params.workspaceId, params.conversationId),
    };
    const res = await fetchImpl(`https://api.clickup.com/api/v2/list/${cfg.listId}/task`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: cfg.apiKey,
      },
      body: JSON.stringify({
        name: buildTicketTitle({
          actionType: params.actionType,
          gist,
          customerEmail: params.customerEmail,
        }),
        markdown_description: buildTicketMarkdown({
          ...contentParams,
          gist,
          sla,
          intercomUrl: intercomDeeplink(params.workspaceId, params.conversationId),
        }),
        status: "to do",
        priority: TIER_TO_PRIORITY[tier],
        due_date: slaDueDateMs(tier, Date.now()),
        due_date_time: false,
        tags: [...buildTicketTags({ actionType: params.actionType, tier }), "intercom-auto-handoff"],
        custom_fields: customFields,
      }),
    });
    if (!res.ok) {
      const bodySample = await res.text().catch(() => "<unreadable>");
      log?.error(
        `[intercom:clickup] ticket POST failed status=${res.status} body=${bodySample.slice(0, 500)}`,
      );
      return { ok: false, error: `ClickUp ${res.status}` };
    }
    const data = (await res.json()) as { id: string };
    return { ok: true, ticketId: data.id, sla };
  } catch (err) {
    log?.error(`[intercom:clickup] ticket POST threw err=${(err as Error)?.message ?? String(err)}`);
    return { ok: false, error: String(err) };
  }
}
