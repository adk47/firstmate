import type { CreateTicketParams, TicketResult } from "./escalation-action.js";
import type { IntercomAccountConfig, RiskActionType } from "./types.js";
import { TIER_BY_ACTION, TIER_PRIORITY, TIER_SLA } from "./types.js";

type ClickupCfg = NonNullable<IntercomAccountConfig["clickup"]>;

interface CreateClickupTicketDeps {
  cfg: ClickupCfg;
  fetchImpl?: typeof fetch;
  log?: { error: (msg: string) => void };
}

function tierFor(actionType: string): 1 | 2 | 3 {
  return TIER_BY_ACTION[actionType as RiskActionType] ?? 1;
}

export async function createClickupTicket(
  deps: CreateClickupTicketDeps,
  params: CreateTicketParams,
): Promise<TicketResult> {
  const { cfg, log } = deps;
  const fetchImpl = deps.fetchImpl ?? fetch;

  const tier = tierFor(params.actionType);
  const customFields: { id: string; value: string }[] = [
    { id: cfg.userEmailFieldId, value: params.customerEmail },
  ];
  if (params.customerProfileId) {
    customFields.push({ id: cfg.profileIdFieldId, value: params.customerProfileId });
  }

  try {
    const res = await fetchImpl(`https://api.clickup.com/api/v2/list/${cfg.listId}/task`, {
      method: "POST",
      headers: {
        "Content-Type": "application/json",
        Authorization: cfg.apiKey,
      },
      body: JSON.stringify({
        name: `Intercom escalation: ${params.actionType}`,
        description: `${params.summary}\n\n${params.conversationSummary}`,
        status: "to do",
        priority: TIER_PRIORITY[tier],
        tags: ["hydra-action-request", `tier-${tier}`, "intercom-auto-handoff"],
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
    return { ok: true, ticketId: data.id, sla: TIER_SLA[tier] };
  } catch (err) {
    log?.error(`[intercom:clickup] ticket POST threw err=${(err as Error)?.message ?? String(err)}`);
    return { ok: false, error: String(err) };
  }
}
