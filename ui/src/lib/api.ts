const API_BASE = process.env.NEXT_PUBLIC_API_URL || '';

export interface Agent {
  id: string;
  name: string;
  owner: string;
  model: string;
  channels: string[];
  status: 'online' | 'offline' | 'degraded';
  lastHeartbeat: string;
  messagestoday: number;
  tokensToday: number;
  costToday: number;
}

export interface AgentDetail extends Agent {
  soulMd: string;
  memoryMd: string;
  memoryVersions: MemoryVersion[];
  denyList: string[];
  egressAllowlist: string[];
}

export interface MemoryVersion {
  version: number;
  timestamp: string;
  diff: string;
}

export interface Message {
  id: string;
  agentId: string;
  agentName: string;
  channel: string;
  content: string;
  timestamp: string;
  tokensUsed: number;
  toolsInvoked: string[];
  crossAgent: boolean;
}

export interface AuditEntry {
  id: string;
  timestamp: string;
  agentId: string;
  agentName: string;
  channel: string;
  action: string;
  messagePreview: string;
  tokensUsed: number;
  toolsInvoked: string[];
  crossAgent: boolean;
}

export interface CostEntry {
  date: string;
  agentId: string;
  agentName: string;
  model: string;
  inputTokens: number;
  outputTokens: number;
  totalCost: number;
}

export interface CostSummary {
  daily: CostEntry[];
  monthly: CostEntry[];
  byAgent: Record<string, number>;
  byModel: Record<string, number>;
  totalToday: number;
  totalThisMonth: number;
}

export interface GovernanceAlert {
  id: string;
  timestamp: string;
  severity: 'critical' | 'warning' | 'info';
  type: 'canary_detection' | 'denial_violation' | 'token_spike' | 'egress_violation' | 'heartbeat_miss';
  agentId: string;
  agentName: string;
  message: string;
  acknowledged: boolean;
  resolvedAt: string | null;
}

export interface SystemHealth {
  status: 'healthy' | 'degraded' | 'down';
  agentsOnline: number;
  agentsTotal: number;
  gatewayStatus: string;
  lastDeployment: string;
  uptime: string;
}

async function fetchAPI<T>(path: string, options?: RequestInit): Promise<T> {
  const res = await fetch(`${API_BASE}${path}`, {
    ...options,
    headers: {
      'Content-Type': 'application/json',
      ...options?.headers,
    },
  });

  if (!res.ok) {
    const error = await res.text();
    throw new Error(`API error ${res.status}: ${error}`);
  }

  return res.json();
}

export const api = {
  // Agents
  getAgents: () => fetchAPI<Agent[]>('/api/agents'),
  getAgent: (id: string) => fetchAPI<AgentDetail>(`/api/agents/${id}`),
  getAgentMessages: (id: string, limit = 50) =>
    fetchAPI<Message[]>(`/api/agents/${id}/messages?limit=${limit}`),
  restartAgent: (id: string) =>
    fetchAPI<{ success: boolean }>(`/api/agents/${id}/restart`, { method: 'POST' }),

  // Audit
  getAuditLog: (params?: {
    agent?: string;
    from?: string;
    to?: string;
    tool?: string;
    crossAgent?: boolean;
    limit?: number;
    offset?: number;
  }) => {
    const query = new URLSearchParams();
    if (params?.agent) query.set('agent', params.agent);
    if (params?.from) query.set('from', params.from);
    if (params?.to) query.set('to', params.to);
    if (params?.tool) query.set('tool', params.tool);
    if (params?.crossAgent !== undefined) query.set('crossAgent', String(params.crossAgent));
    if (params?.limit) query.set('limit', String(params.limit));
    if (params?.offset) query.set('offset', String(params.offset));
    return fetchAPI<AuditEntry[]>(`/api/audit?${query.toString()}`);
  },

  // Costs
  getCosts: (period?: 'daily' | 'monthly') =>
    fetchAPI<CostSummary>(`/api/costs${period ? `?period=${period}` : ''}`),

  // Alerts
  getAlerts: (acknowledged?: boolean) => {
    const query = acknowledged !== undefined ? `?acknowledged=${acknowledged}` : '';
    return fetchAPI<GovernanceAlert[]>(`/api/alerts${query}`);
  },
  acknowledgeAlert: (id: string) =>
    fetchAPI<{ success: boolean }>(`/api/alerts`, {
      method: 'PATCH',
      body: JSON.stringify({ id, acknowledged: true }),
    }),
  resolveAlert: (id: string) =>
    fetchAPI<{ success: boolean }>(`/api/alerts`, {
      method: 'PATCH',
      body: JSON.stringify({ id, resolved: true }),
    }),

  // Policies
  updateDenyLists: (changes: Record<string, string[]>) =>
    fetchAPI<{ prUrl: string }>('/api/policies/deny-lists', {
      method: 'PUT',
      body: JSON.stringify(changes),
    }),

  // Health
  getHealth: () => fetchAPI<SystemHealth>('/api/health'),
};
