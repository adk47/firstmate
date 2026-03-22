import { NextRequest, NextResponse } from 'next/server';
import { readFile } from 'fs/promises';
import path from 'path';

const OPENCLAW_PATH = process.env.OPENCLAW_CONFIG_PATH || '/opt/hydra/config/openclaw.json';
const WORKSPACES_PATH = process.env.WORKSPACES_PATH || '/opt/hydra/config/workspaces';
const AUDIT_LOG_PATH = process.env.AUDIT_LOG_PATH || '/var/log/hydra/audit.jsonl';
const DENY_LISTS_PATH = process.env.DENY_LISTS_PATH || '/opt/hydra/config/policies/tool-deny-lists.yaml';

async function readFileSafe(filePath: string): Promise<string> {
  try {
    return await readFile(filePath, 'utf-8');
  } catch {
    return '';
  }
}

export async function GET(
  request: NextRequest,
  { params }: { params: { id: string } }
) {
  const agentId = params.id;

  // Load openclaw config
  let config: Record<string, unknown> = {};
  try {
    const raw = await readFile(OPENCLAW_PATH, 'utf-8');
    const parsed = JSON.parse(raw);
    config = parsed.workspaces?.[agentId] || {};
  } catch {
    // fallback
  }

  // Load SOUL.md
  const soulMd = await readFileSafe(path.join(WORKSPACES_PATH, agentId, 'SOUL.md'));

  // Load MEMORY.md
  const memoryMd = await readFileSafe(path.join(WORKSPACES_PATH, agentId, 'MEMORY.md'));

  // Get pod status
  let status: 'online' | 'offline' | 'degraded' = 'offline';
  let lastHeartbeat = '';
  try {
    const { execSync } = await import('child_process');
    const result = execSync(
      `kubectl get pods -n hydra -l agent=${agentId} -o jsonpath='{.items[0].status.phase}'`,
      { timeout: 5000, encoding: 'utf-8' }
    );
    const phase = result.trim().replace(/'/g, '');
    status = phase === 'Running' ? 'online' : phase === 'Pending' ? 'degraded' : 'offline';

    const readyResult = execSync(
      `kubectl get pods -n hydra -l agent=${agentId} -o jsonpath='{.items[0].status.conditions[?(@.type=="Ready")].lastTransitionTime}'`,
      { timeout: 5000, encoding: 'utf-8' }
    );
    lastHeartbeat = readyResult.trim().replace(/'/g, '');
  } catch {
    // offline
  }

  // Parse deny lists for this agent
  const denyList: string[] = [];
  try {
    const denyRaw = await readFile(DENY_LISTS_PATH, 'utf-8');
    // Simple YAML parsing for agent section
    const lines = denyRaw.split('\n');
    let inAgent = false;
    let inTools = false;
    for (const line of lines) {
      if (line.match(new RegExp(`^\\s*${agentId}:`))) {
        inAgent = true;
        continue;
      }
      if (inAgent && line.match(/^\s+tools:/)) {
        inTools = true;
        continue;
      }
      if (inAgent && inTools && line.match(/^\s+-\s+/)) {
        denyList.push(line.replace(/^\s+-\s+/, '').trim());
      }
      if (inAgent && inTools && !line.match(/^\s+-/) && line.trim() !== '') {
        inAgent = false;
        inTools = false;
      }
    }
  } catch {
    // no deny lists
  }

  // Get today stats from audit log
  let messagestoday = 0;
  let tokensToday = 0;
  let costToday = 0;
  try {
    const raw = await readFile(AUDIT_LOG_PATH, 'utf-8');
    const today = new Date().toISOString().split('T')[0];
    for (const line of raw.trim().split('\n')) {
      try {
        const entry = JSON.parse(line);
        if (entry.agentId === agentId && entry.timestamp?.startsWith(today)) {
          messagestoday++;
          tokensToday += entry.tokensUsed || 0;
          costToday += entry.cost || 0;
        }
      } catch {
        continue;
      }
    }
  } catch {
    // no audit
  }

  return NextResponse.json({
    id: agentId,
    name: (config as { name?: string }).name || agentId,
    owner: (config as { owner?: string }).owner || 'unknown',
    model: (config as { model?: string }).model || 'unknown',
    channels: (config as { channels?: string[] }).channels || [],
    status,
    lastHeartbeat,
    messagestoday,
    tokensToday,
    costToday,
    soulMd,
    memoryMd,
    memoryVersions: [], // TODO: integrate with git log for version history
    denyList,
    egressAllowlist: [],
  });
}
