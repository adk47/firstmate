'use client';

import { useEffect, useState } from 'react';
import Link from 'next/link';
import {
  Activity,
  Bot,
  MessageSquare,
  Coins,
  Zap,
  Clock,
  AlertTriangle,
  CheckCircle2,
  XCircle,
} from 'lucide-react';
import type { Agent, SystemHealth } from '@/lib/api';

const AGENT_DEFINITIONS = [
  { id: 'coordinator', name: 'Coordinator', owner: 'system', model: 'opus' },
  { id: 'ceo', name: 'CEO', owner: 'aaron', model: 'opus' },
  { id: 'cto', name: 'CTO', owner: 'aaron', model: 'opus' },
  { id: 'cmo', name: 'CMO', owner: 'aaron', model: 'sonnet' },
  { id: 'devops', name: 'DevOps', owner: 'aaron', model: 'opus' },
  { id: 'finance', name: 'Finance', owner: 'aaron', model: 'sonnet' },
  { id: 'design', name: 'Design', owner: 'aaron', model: 'sonnet' },
  { id: 'operations', name: 'Operations', owner: 'aaron', model: 'sonnet' },
  { id: 'qa', name: 'QA', owner: 'aaron', model: 'sonnet' },
];

function StatusDot({ status }: { status: string }) {
  const colors: Record<string, string> = {
    online: 'bg-green-500 shadow-green-500/50',
    offline: 'bg-red-500 shadow-red-500/50',
    degraded: 'bg-yellow-500 shadow-yellow-500/50',
  };
  return (
    <span
      className={`inline-block w-2.5 h-2.5 rounded-full shadow-lg ${colors[status] || colors.offline}`}
    />
  );
}

function AgentCard({ agent }: { agent: Agent }) {
  const modelBadge: Record<string, string> = {
    opus: 'badge-blue',
    sonnet: 'badge-green',
  };

  return (
    <Link href={`/agents/${agent.id}`}>
      <div className="card-hover cursor-pointer">
        <div className="flex items-start justify-between mb-4">
          <div className="flex items-center gap-3">
            <div className="w-10 h-10 bg-gray-800 rounded-lg flex items-center justify-center">
              <Bot className="w-5 h-5 text-hydra-400" />
            </div>
            <div>
              <h3 className="font-semibold text-white">{agent.name}</h3>
              <p className="text-xs text-gray-500">{agent.owner}</p>
            </div>
          </div>
          <StatusDot status={agent.status} />
        </div>

        <div className="space-y-2">
          <div className="flex items-center justify-between text-sm">
            <span className="text-gray-500">Model</span>
            <span className={modelBadge[agent.model] || 'badge'}>{agent.model}</span>
          </div>
          <div className="flex items-center justify-between text-sm">
            <span className="text-gray-500">Messages</span>
            <span className="text-gray-300">{agent.messagestoday.toLocaleString()}</span>
          </div>
          <div className="flex items-center justify-between text-sm">
            <span className="text-gray-500">Tokens</span>
            <span className="text-gray-300">{agent.tokensToday.toLocaleString()}</span>
          </div>
          <div className="flex items-center justify-between text-sm">
            <span className="text-gray-500">Last heartbeat</span>
            <span className="text-gray-400 text-xs">{agent.lastHeartbeat || 'never'}</span>
          </div>
        </div>
      </div>
    </Link>
  );
}

export default function Dashboard() {
  const [agents, setAgents] = useState<Agent[]>([]);
  const [health, setHealth] = useState<SystemHealth | null>(null);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const [agentsRes, healthRes] = await Promise.allSettled([
          fetch('/api/agents').then((r) => r.json()),
          fetch('/api/health').then((r) => r.json()),
        ]);

        if (agentsRes.status === 'fulfilled') {
          setAgents(agentsRes.value);
        } else {
          // Fallback to definitions with unknown status
          setAgents(
            AGENT_DEFINITIONS.map((d) => ({
              ...d,
              channels: [],
              status: 'offline' as const,
              lastHeartbeat: '',
              messagestoday: 0,
              tokensToday: 0,
              costToday: 0,
            }))
          );
        }

        if (healthRes.status === 'fulfilled') {
          setHealth(healthRes.value);
        }
      } catch {
        // Use defaults
      } finally {
        setLoading(false);
      }
    }
    load();
  }, []);

  const totalMessages = agents.reduce((s, a) => s + a.messagestoday, 0);
  const totalTokens = agents.reduce((s, a) => s + a.tokensToday, 0);
  const totalCost = agents.reduce((s, a) => s + a.costToday, 0);
  const onlineCount = agents.filter((a) => a.status === 'online').length;

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-white">Dashboard</h1>
        <p className="text-gray-500 mt-1">HYDRA multi-agent orchestration overview</p>
      </div>

      {/* Quick stats */}
      <div className="grid grid-cols-1 md:grid-cols-4 gap-4 mb-8">
        <div className="card">
          <div className="flex items-center gap-3 mb-2">
            <Activity className="w-5 h-5 text-green-400" />
            <span className="text-sm text-gray-400">System Health</span>
          </div>
          <div className="flex items-center gap-2">
            {health?.status === 'healthy' ? (
              <CheckCircle2 className="w-5 h-5 text-green-400" />
            ) : health?.status === 'degraded' ? (
              <AlertTriangle className="w-5 h-5 text-yellow-400" />
            ) : (
              <XCircle className="w-5 h-5 text-red-400" />
            )}
            <span className="text-2xl font-bold text-white">
              {loading ? '--' : `${onlineCount}/${agents.length}`}
            </span>
            <span className="text-sm text-gray-500">agents online</span>
          </div>
        </div>

        <div className="card">
          <div className="flex items-center gap-3 mb-2">
            <MessageSquare className="w-5 h-5 text-hydra-400" />
            <span className="text-sm text-gray-400">Messages Today</span>
          </div>
          <p className="text-2xl font-bold text-white">
            {loading ? '--' : totalMessages.toLocaleString()}
          </p>
        </div>

        <div className="card">
          <div className="flex items-center gap-3 mb-2">
            <Zap className="w-5 h-5 text-yellow-400" />
            <span className="text-sm text-gray-400">Tokens Today</span>
          </div>
          <p className="text-2xl font-bold text-white">
            {loading ? '--' : totalTokens.toLocaleString()}
          </p>
        </div>

        <div className="card">
          <div className="flex items-center gap-3 mb-2">
            <Coins className="w-5 h-5 text-emerald-400" />
            <span className="text-sm text-gray-400">Estimated Cost</span>
          </div>
          <p className="text-2xl font-bold text-white">
            {loading ? '--' : `$${totalCost.toFixed(2)}`}
          </p>
        </div>
      </div>

      {/* Agent grid */}
      <div className="mb-4">
        <h2 className="text-lg font-semibold text-white">Agents</h2>
      </div>

      {loading ? (
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {Array.from({ length: 9 }).map((_, i) => (
            <div key={i} className="card animate-pulse">
              <div className="h-10 bg-gray-800 rounded mb-4" />
              <div className="space-y-3">
                <div className="h-4 bg-gray-800 rounded w-3/4" />
                <div className="h-4 bg-gray-800 rounded w-1/2" />
                <div className="h-4 bg-gray-800 rounded w-2/3" />
              </div>
            </div>
          ))}
        </div>
      ) : (
        <div className="grid grid-cols-1 md:grid-cols-3 gap-4">
          {agents.map((agent) => (
            <AgentCard key={agent.id} agent={agent} />
          ))}
        </div>
      )}
    </div>
  );
}
