import type { JudgeInput, JudgeOutput, AssessRiskDeps } from "./escalation.js";
import type { RiskActionType } from "./types.js";

const JUDGE_SYSTEM_PROMPT = `You are a customer-support quality monitor. Given the recent
conversation between a paying user and an AI support agent, decide if the conversation
should be handed off to a human teammate now. Score quietly — most conversations should
NOT be handed off. Only recommend handoff when the user is clearly frustrated, asking
the same thing repeatedly without resolution, threatening public escalation (BBB, social
media), or stuck in a loop. A refund or cancellation request that the agent is actively
working through (diagnosing the reason, offering a retention discount or downgrade) is
NOT by itself a handoff reason — the agent owns that flow; hand off only when the user
declines the agent's help or asks to just proceed and the agent is not progressing.

Respond with strict JSON only, matching this schema exactly:
{
  "shouldHandoff": boolean,
  "reasons": string[],          // pick from: "frustration", "repeated_question", "stuck_in_loop", "refund_intent", "cancel_intent", "public_shaming_intent", "ambiguous"
  "suggestedActionType": "subscription-refund" | "dispute" | "support-general",
  "confidence": "low" | "medium" | "high"
}

No prose, no commentary, just JSON.`;

const ALLOWED_ACTION_TYPES: ReadonlyArray<RiskActionType> = [
  "subscription-refund",
  "dispute",
  "support-general",
];
const ALLOWED_CONFIDENCE = ["low", "medium", "high"] as const;

// Cap inputs before stringify so a long conversation doesn't bloat the request,
// burn cost, or force the 8s timeout to fail-close every call.
const MAX_PART_LENGTH = 500;
const MAX_RECENT_PARTS = 10;
const MAX_CURRENT_MESSAGE = 2_000;

function trimPart(p: { author: "user" | "bot"; body: string }): { author: "user" | "bot"; body: string } {
  return { author: p.author, body: p.body.length > MAX_PART_LENGTH ? p.body.slice(0, MAX_PART_LENGTH) : p.body };
}

export interface JudgeFactoryDeps {
  openrouterApiKey: string;
  model: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
  log?: { warn: (msg: string) => void };
}

export function createOpenRouterJudge(deps: JudgeFactoryDeps): AssessRiskDeps["judge"] {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const timeoutMs = deps.timeoutMs ?? 8_000;
  const warn = (msg: string) => deps.log?.warn?.(msg);

  return async (input: JudgeInput): Promise<JudgeOutput | null> => {
    const recent = input.recentParts.slice(-MAX_RECENT_PARTS).map(trimPart);
    const currentMessage =
      input.currentMessage.length > MAX_CURRENT_MESSAGE
        ? input.currentMessage.slice(0, MAX_CURRENT_MESSAGE)
        : input.currentMessage;
    const userMsg = JSON.stringify({
      knownFacts: input.knownFacts,
      recentParts: recent,
      currentMessage,
    });

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);

    try {
      const res = await fetchImpl("https://openrouter.ai/api/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${deps.openrouterApiKey}`,
        },
        body: JSON.stringify({
          model: deps.model,
          messages: [
            { role: "system", content: JUDGE_SYSTEM_PROMPT },
            { role: "user", content: userMsg },
          ],
          response_format: { type: "json_object" },
          max_tokens: 300,
          temperature: 0,
        }),
        signal: ctrl.signal,
      });
      if (!res.ok) {
        throw new Error(`openrouter status ${res.status}`);
      }
      const data: any = await res.json();
      const content = data?.choices?.[0]?.message?.content;
      if (typeof content !== "string") {
        warn(`[intercom:judge] response missing content`);
        return null;
      }
      let parsed: any;
      try {
        parsed = JSON.parse(content);
      } catch (err) {
        warn(`[intercom:judge] JSON.parse failed sample=${content.slice(0, 200)} err=${(err as Error).message}`);
        return null;
      }
      if (
        typeof parsed.shouldHandoff !== "boolean" ||
        !Array.isArray(parsed.reasons) ||
        !parsed.reasons.every((r: unknown) => typeof r === "string") ||
        !ALLOWED_ACTION_TYPES.includes(parsed.suggestedActionType) ||
        !ALLOWED_CONFIDENCE.includes(parsed.confidence)
      ) {
        warn(`[intercom:judge] shape rejected sample=${content.slice(0, 200)}`);
        return null;
      }
      return parsed as JudgeOutput;
    } finally {
      clearTimeout(timer);
    }
  };
}
