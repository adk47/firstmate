import { NextResponse } from 'next/server';
import { readFile } from 'fs/promises';
import path from 'path';

const OPENCLAW_PATH = process.env.OPENCLAW_CONFIG_PATH || '/opt/hydra/config/openclaw.json';
const AUDIT_LOG_PATH = process.env.AUDIT_LOG_PATH || '/var/log/hydra/audit.jsonl';

interface OpenClawConfig {
  workspaces: Record<string, {
    name: string;
    owner: string;
    model: string;
    channels: string[];
  }>;
}

async function loadConfig(): Promise<OpenClawConfig | null> {
  try {
    const raw = await readFile(OPENCLAW_PATH, 'utf-8');
    return JSON.parse(raw);
  } catch {
    return null;
  }
}

async function getAgentStatus(agentId: string): Promise<{
  status: 'online' | 'offline' | 'degraded';
  lastHeartbeat: string;
}> {
  // Check K8s pod status via kubectl or API
  try {
    const { execSync } = await import('child_process');
    const result = execSync(
      `kubectl get pods -n hydra -l agent=${agentId} -o jsonpath='{.items[0].status.phase}'`,
      { timeout: 5000, encoding: 'utf-8' }
    );
    const phase = result.trim().replace(/'/g, '');
    const status = phase === 'Running' ? 'online' : phase === 'Pending' ? 'degraded' : 'offline';

    const readyResult = execSync(
      `kubectl get pods -n hydra -l agent=${agentId} -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].lastTransitionTime}'`,
      { timeout: 5000, encoding: 'utf-8' }
    );
    const lastHeartbeat = readyResult.trim().replace(/'/g, '');

    return { status, lastHeartbeat };
  } catch {
    return { status: 'offline', lastHeartbeat: '' };
  }
}

async function getTodayStats(agentId: string): Promise<{
  messagestoday: number;
  tokensToday: number;
  costToday: number;
}> {
  try {
    const raw = await readFile(AUDIT_LOG_PATH, 'utf-8');
    const today = new Date().toISOString().split('T')[0];
    const lines = raw.trim().split('\n').filter(Boolean);

    let messages = 0;
    let tokens = 0;
    let cost = 0;

    for (const line of lines) {
      try {
        const entry = JSON.parse(line);
        if (entry.agentId === agentId && entry.timestamp?.startsWith(today)) {
          messages++;
          tokens += entry.tokensUsed || 0;
          cost += entry.cost || 0;
        }
      } catch {
        continue;
      }
    }

    return { messagestoday: messages, tokensToday: tokens, costToday: cost };
  } catch {
    return { messagestoday: 0, tokensToday: 0, costToday: 0 };
  }
}

export async function GET() {
  const config = await loadConfig();

  if (!config?.workspaces) {
    return NextResponse.json([], { status: 200 });
  }

  const agents = await Promise.all(
    Object.entries(config.workspaces).map(async ([id, ws]) => {
      const [podStatus, stats] = await Promise.all([
        getAgentStatus(id),
        getTodayStats(id),
      ]);

      return {
        id,
        name: ws.name,
        owner: ws.owner,
        model: ws.model,
        channels: ws.channels || [],
        status: podStatus.status,
        lastHeartbeat: podStatus.lastHeartbeat,
        ...stats,
      };
    })
  );

  return NextResponse.json(agents);
}
