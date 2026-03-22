import { NextRequest, NextResponse } from 'next/server';
import { readFile } from 'fs/promises';

const AUDIT_LOG_PATH = process.env.AUDIT_LOG_PATH || '/var/log/hydra/audit.jsonl';

// Cost per 1M tokens (approximate Anthropic pricing)
const MODEL_COSTS: Record<string, { input: number; output: number }> = {
  opus: { input: 15.0, output: 75.0 },
  sonnet: { input: 3.0, output: 15.0 },
  haiku: { input: 0.25, output: 1.25 },
};

function estimateCost(model: string, inputTokens: number, outputTokens: number): number {
  const rates = MODEL_COSTS[model] || MODEL_COSTS.sonnet;
  return (inputTokens / 1_000_000) * rates.input + (outputTokens / 1_000_000) * rates.output;
}

export async function GET(request: NextRequest) {
  const period = request.nextUrl.searchParams.get('period') || 'daily';

  try {
    const raw = await readFile(AUDIT_LOG_PATH, 'utf-8');
    const lines = raw.trim().split('\n').filter(Boolean);

    const today = new Date().toISOString().split('T')[0];
    const thisMonth = today.substring(0, 7); // YYYY-MM

    const daily: Record<string, { date: string; agentId: string; agentName: string; model: string; inputTokens: number; outputTokens: number; totalCost: number }> = {};
    const byAgent: Record<string, number> = {};
    const byModel: Record<string, number> = {};
    let totalToday = 0;
    let totalThisMonth = 0;

    for (const line of lines) {
      try {
        const entry = JSON.parse(line);
        const date = entry.timestamp?.split('T')[0];
        if (!date) continue;

        const agentId = entry.agentId || 'unknown';
        const agentName = entry.agentName || agentId;
        const model = entry.model || 'sonnet';
        const inputTokens = entry.inputTokens || Math.floor((entry.tokensUsed || 0) * 0.3);
        const outputTokens = entry.outputTokens || Math.floor((entry.tokensUsed || 0) * 0.7);
        const cost = entry.cost || estimateCost(model, inputTokens, outputTokens);

        const key = `${date}-${agentId}`;
        if (!daily[key]) {
          daily[key] = { date, agentId, agentName, model, inputTokens: 0, outputTokens: 0, totalCost: 0 };
        }
        daily[key].inputTokens += inputTokens;
        daily[key].outputTokens += outputTokens;
        daily[key].totalCost += cost;

        if (date === today) totalToday += cost;
        if (date.startsWith(thisMonth)) totalThisMonth += cost;

        byAgent[agentName] = (byAgent[agentName] || 0) + cost;
        byModel[model] = (byModel[model] || 0) + cost;
      } catch {
        continue;
      }
    }

    const dailyEntries = Object.values(daily).sort((a, b) => a.date.localeCompare(b.date));

    // Monthly aggregation
    const monthlyMap: Record<string, typeof daily[string]> = {};
    for (const entry of dailyEntries) {
      const month = entry.date.substring(0, 7);
      const key = `${month}-${entry.agentId}`;
      if (!monthlyMap[key]) {
        monthlyMap[key] = { ...entry, date: month };
      } else {
        monthlyMap[key].inputTokens += entry.inputTokens;
        monthlyMap[key].outputTokens += entry.outputTokens;
        monthlyMap[key].totalCost += entry.totalCost;
      }
    }
    const monthlyEntries = Object.values(monthlyMap).sort((a, b) => a.date.localeCompare(b.date));

    return NextResponse.json({
      daily: dailyEntries,
      monthly: monthlyEntries,
      byAgent,
      byModel,
      totalToday,
      totalThisMonth,
    });
  } catch {
    return NextResponse.json({
      daily: [],
      monthly: [],
      byAgent: {},
      byModel: {},
      totalToday: 0,
      totalThisMonth: 0,
    });
  }
}
