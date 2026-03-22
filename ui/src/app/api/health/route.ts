import { NextResponse } from 'next/server';

export async function GET() {
  let agentsOnline = 0;
  let agentsTotal = 9;
  let gatewayStatus = 'unknown';
  let lastDeployment = '';
  let uptime = '';

  try {
    const { execSync } = await import('child_process');

    // Count running agent pods
    try {
      const podsResult = execSync(
        `kubectl get pods -n hydra -l component=agent --no-headers 2>/dev/null | wc -l`,
        { timeout: 10000, encoding: 'utf-8' }
      );
      agentsTotal = parseInt(podsResult.trim(), 10) || 9;

      const runningResult = execSync(
        `kubectl get pods -n hydra -l component=agent --field-selector=status.phase=Running --no-headers 2>/dev/null | wc -l`,
        { timeout: 10000, encoding: 'utf-8' }
      );
      agentsOnline = parseInt(runningResult.trim(), 10) || 0;
    } catch {
      // fallback
    }

    // Gateway status
    try {
      const gwResult = execSync(
        `kubectl get deployment openclaw-gateway -n hydra -o jsonpath='{.status.readyReplicas}' 2>/dev/null`,
        { timeout: 5000, encoding: 'utf-8' }
      );
      const ready = parseInt(gwResult.trim().replace(/'/g, ''), 10);
      gatewayStatus = ready > 0 ? 'running' : 'down';
    } catch {
      gatewayStatus = 'unknown';
    }

    // Last deployment time
    try {
      const deployResult = execSync(
        `kubectl get deployment openclaw-gateway -n hydra -o jsonpath='{.metadata.annotations.kubectl\\.kubernetes\\.io/restartedAt}' 2>/dev/null`,
        { timeout: 5000, encoding: 'utf-8' }
      );
      lastDeployment = deployResult.trim().replace(/'/g, '') || 'unknown';
    } catch {
      lastDeployment = 'unknown';
    }

    // Node uptime
    try {
      const uptimeResult = execSync('uptime -p 2>/dev/null || uptime', {
        timeout: 5000,
        encoding: 'utf-8',
      });
      uptime = uptimeResult.trim();
    } catch {
      uptime = 'unknown';
    }
  } catch {
    // all defaults
  }

  const status =
    agentsOnline === agentsTotal && gatewayStatus === 'running'
      ? 'healthy'
      : agentsOnline > 0
        ? 'degraded'
        : 'down';

  return NextResponse.json({
    status,
    agentsOnline,
    agentsTotal,
    gatewayStatus,
    lastDeployment,
    uptime,
  });
}
