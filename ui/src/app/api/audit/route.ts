import { NextRequest, NextResponse } from 'next/server';
import { readFile } from 'fs/promises';

const AUDIT_LOG_PATH = process.env.AUDIT_LOG_PATH || '/var/log/hydra/audit.jsonl';

export async function GET(request: NextRequest) {
  const searchParams = request.nextUrl.searchParams;
  const agentFilter = searchParams.get('agent');
  const fromDate = searchParams.get('from');
  const toDate = searchParams.get('to');
  const toolFilter = searchParams.get('tool');
  const crossAgentFilter = searchParams.get('crossAgent');
  const limit = parseInt(searchParams.get('limit') || '50', 10);
  const offset = parseInt(searchParams.get('offset') || '0', 10);

  try {
    const raw = await readFile(AUDIT_LOG_PATH, 'utf-8');
    const lines = raw.trim().split('\n').filter(Boolean);

    let entries = [];
    for (const line of lines) {
      try {
        const entry = JSON.parse(line);
        entries.push({
          id: entry.id || entries.length.toString(),
          timestamp: entry.timestamp,
          agentId: entry.agentId,
          agentName: entry.agentName || entry.agentId,
          channel: entry.channel || 'unknown',
          action: entry.action || 'message',
          messagePreview: entry.message || entry.messagePreview || '',
          tokensUsed: entry.tokensUsed || 0,
          toolsInvoked: entry.toolsInvoked || [],
          crossAgent: entry.crossAgent || false,
        });
      } catch {
        continue;
      }
    }

    // Apply filters
    if (agentFilter) {
      entries = entries.filter((e) => e.agentId === agentFilter);
    }
    if (fromDate) {
      entries = entries.filter((e) => e.timestamp >= fromDate);
    }
    if (toDate) {
      const toEnd = toDate + 'T23:59:59.999Z';
      entries = entries.filter((e) => e.timestamp <= toEnd);
    }
    if (toolFilter) {
      entries = entries.filter((e) =>
        e.toolsInvoked.some((t: string) => t.toLowerCase().includes(toolFilter.toLowerCase()))
      );
    }
    if (crossAgentFilter === 'true') {
      entries = entries.filter((e) => e.crossAgent);
    }

    // Sort by timestamp descending (most recent first)
    entries.sort((a, b) => b.timestamp.localeCompare(a.timestamp));

    // Paginate
    const paginated = entries.slice(offset, offset + limit);

    return NextResponse.json(paginated);
  } catch {
    return NextResponse.json([]);
  }
}
