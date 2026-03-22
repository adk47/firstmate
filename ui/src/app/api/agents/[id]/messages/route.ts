import { NextRequest, NextResponse } from 'next/server';
import { readFile } from 'fs/promises';

const AUDIT_LOG_PATH = process.env.AUDIT_LOG_PATH || '/var/log/hydra/audit.jsonl';

export async function GET(
  request: NextRequest,
  { params }: { params: { id: string } }
) {
  const agentId = params.id;
  const searchParams = request.nextUrl.searchParams;
  const limit = parseInt(searchParams.get('limit') || '50', 10);

  try {
    const raw = await readFile(AUDIT_LOG_PATH, 'utf-8');
    const lines = raw.trim().split('\n').filter(Boolean);

    const messages = [];
    // Read from end for most recent
    for (let i = lines.length - 1; i >= 0 && messages.length < limit; i--) {
      try {
        const entry = JSON.parse(lines[i]);
        if (entry.agentId === agentId) {
          messages.push({
            id: entry.id || `${i}`,
            agentId: entry.agentId,
            agentName: entry.agentName || agentId,
            channel: entry.channel || 'unknown',
            content: entry.message || entry.messagePreview || '',
            timestamp: entry.timestamp,
            tokensUsed: entry.tokensUsed || 0,
            toolsInvoked: entry.toolsInvoked || [],
            crossAgent: entry.crossAgent || false,
          });
        }
      } catch {
        continue;
      }
    }

    return NextResponse.json(messages);
  } catch {
    return NextResponse.json([]);
  }
}
