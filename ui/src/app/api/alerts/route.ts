import { NextRequest, NextResponse } from 'next/server';
import { readFile, writeFile } from 'fs/promises';

const ALERTS_PATH = process.env.ALERTS_PATH || '/var/log/hydra/alerts.jsonl';

interface StoredAlert {
  id: string;
  timestamp: string;
  severity: 'critical' | 'warning' | 'info';
  type: string;
  agentId: string;
  agentName: string;
  message: string;
  acknowledged: boolean;
  resolvedAt: string | null;
}

async function loadAlerts(): Promise<StoredAlert[]> {
  try {
    const raw = await readFile(ALERTS_PATH, 'utf-8');
    return raw
      .trim()
      .split('\n')
      .filter(Boolean)
      .map((line) => {
        try {
          return JSON.parse(line);
        } catch {
          return null;
        }
      })
      .filter(Boolean) as StoredAlert[];
  } catch {
    return [];
  }
}

async function saveAlerts(alerts: StoredAlert[]): Promise<void> {
  const data = alerts.map((a) => JSON.stringify(a)).join('\n') + '\n';
  await writeFile(ALERTS_PATH, data, 'utf-8');
}

export async function GET(request: NextRequest) {
  const acknowledgedParam = request.nextUrl.searchParams.get('acknowledged');

  let alerts = await loadAlerts();

  if (acknowledgedParam === 'false') {
    alerts = alerts.filter((a) => !a.acknowledged);
  } else if (acknowledgedParam === 'true') {
    alerts = alerts.filter((a) => a.acknowledged);
  }

  // Sort by timestamp descending
  alerts.sort((a, b) => b.timestamp.localeCompare(a.timestamp));

  return NextResponse.json(alerts);
}

export async function PATCH(request: NextRequest) {
  try {
    const body = await request.json();
    const { id, acknowledged, resolved } = body;

    if (!id) {
      return NextResponse.json({ error: 'Missing alert id' }, { status: 400 });
    }

    const alerts = await loadAlerts();
    const alert = alerts.find((a) => a.id === id);

    if (!alert) {
      return NextResponse.json({ error: 'Alert not found' }, { status: 404 });
    }

    if (acknowledged !== undefined) {
      alert.acknowledged = acknowledged;
    }
    if (resolved) {
      alert.resolvedAt = new Date().toISOString();
    }

    await saveAlerts(alerts);

    return NextResponse.json({ success: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return NextResponse.json({ error: message }, { status: 500 });
  }
}
