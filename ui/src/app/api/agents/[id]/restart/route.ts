import { NextRequest, NextResponse } from 'next/server';

export async function POST(
  request: NextRequest,
  { params }: { params: { id: string } }
) {
  const agentId = params.id;

  try {
    const { execSync } = await import('child_process');

    // Restart the agent pod by doing a rollout restart
    execSync(
      `kubectl rollout restart deployment/${agentId}-agent -n hydra`,
      { timeout: 15000, encoding: 'utf-8' }
    );

    // Wait for rollout to complete (up to 60s)
    execSync(
      `kubectl rollout status deployment/${agentId}-agent -n hydra --timeout=60s`,
      { timeout: 65000, encoding: 'utf-8' }
    );

    return NextResponse.json({ success: true });
  } catch (error) {
    const message = error instanceof Error ? error.message : 'Unknown error';
    return NextResponse.json(
      { success: false, error: `Failed to restart agent ${agentId}: ${message}` },
      { status: 500 }
    );
  }
}
