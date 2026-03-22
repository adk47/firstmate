'use client';

import { useEffect, useState } from 'react';
import { useParams, useRouter } from 'next/navigation';
import {
  ArrowLeft,
  Bot,
  RefreshCw,
  MessageSquare,
  FileText,
  Brain,
  Clock,
  Zap,
} from 'lucide-react';
import {
  BarChart,
  Bar,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  PieChart,
  Pie,
  Cell,
} from 'recharts';
import type { AgentDetail, Message } from '@/lib/api';

const MODEL_COLORS: Record<string, string> = {
  opus: '#1b83f5',
  sonnet: '#34d399',
  haiku: '#fbbf24',
};

function StatusBadge({ status }: { status: string }) {
  const styles: Record<string, string> = {
    online: 'badge-green',
    offline: 'badge-red',
    degraded: 'badge-yellow',
  };
  return <span className={styles[status] || 'badge'}>{status}</span>;
}

export default function AgentDetailPage() {
  const params = useParams();
  const router = useRouter();
  const agentId = params.id as string;

  const [agent, setAgent] = useState<AgentDetail | null>(null);
  const [messages, setMessages] = useState<Message[]>([]);
  const [activeTab, setActiveTab] = useState<'messages' | 'soul' | 'memory'>('messages');
  const [restarting, setRestarting] = useState(false);
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const [agentRes, messagesRes] = await Promise.allSettled([
          fetch(`/api/agents/${agentId}`).then((r) => r.json()),
          fetch(`/api/agents/${agentId}/messages`).then((r) => r.json()),
        ]);
        if (agentRes.status === 'fulfilled') setAgent(agentRes.value);
        if (messagesRes.status === 'fulfilled') setMessages(messagesRes.value);
      } catch {
        // handle error
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [agentId]);

  async function handleRestart() {
    if (!confirm(`Restart agent "${agent?.name}"?`)) return;
    setRestarting(true);
    try {
      await fetch(`/api/agents/${agentId}/restart`, { method: 'POST' });
      // Reload agent data after restart
      const res = await fetch(`/api/agents/${agentId}`);
      setAgent(await res.json());
    } catch {
      alert('Failed to restart agent');
    } finally {
      setRestarting(false);
    }
  }

  // Mock token usage data for chart
  const tokenUsageData = Array.from({ length: 7 }, (_, i) => ({
    day: new Date(Date.now() - (6 - i) * 86400000).toLocaleDateString('en-US', { weekday: 'short' }),
    tokens: Math.floor(Math.random() * 50000) + 5000,
  }));

  const modelDistribution = [
    { name: 'opus', value: 60 },
    { name: 'sonnet', value: 30 },
    { name: 'haiku', value: 10 },
  ];

  if (loading) {
    return (
      <div className="animate-pulse space-y-6">
        <div className="h-8 bg-gray-800 rounded w-48" />
        <div className="h-48 bg-gray-800 rounded" />
        <div className="h-96 bg-gray-800 rounded" />
      </div>
    );
  }

  return (
    <div>
      {/* Header */}
      <div className="flex items-center gap-4 mb-8">
        <button
          onClick={() => router.push('/')}
          className="p-2 hover:bg-gray-800 rounded-lg transition-colors"
        >
          <ArrowLeft className="w-5 h-5 text-gray-400" />
        </button>
        <div className="flex-1">
          <div className="flex items-center gap-3">
            <Bot className="w-6 h-6 text-hydra-400" />
            <h1 className="text-2xl font-bold text-white">{agent?.name || agentId}</h1>
            {agent && <StatusBadge status={agent.status} />}
          </div>
          <p className="text-gray-500 mt-1">
            Owner: {agent?.owner} | Model: {agent?.model} | Channels: {agent?.channels?.join(', ') || 'none'}
          </p>
        </div>
        <button
          onClick={handleRestart}
          disabled={restarting}
          className="btn-danger flex items-center gap-2"
        >
          <RefreshCw className={`w-4 h-4 ${restarting ? 'animate-spin' : ''}`} />
          {restarting ? 'Restarting...' : 'Restart'}
        </button>
      </div>

      {/* Charts row */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6 mb-8">
        <div className="card">
          <h3 className="text-sm font-medium text-gray-400 mb-4">Token Usage (7 days)</h3>
          <ResponsiveContainer width="100%" height={200}>
            <BarChart data={tokenUsageData}>
              <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
              <XAxis dataKey="day" tick={{ fill: '#9ca3af', fontSize: 12 }} />
              <YAxis tick={{ fill: '#9ca3af', fontSize: 12 }} />
              <Tooltip
                contentStyle={{ backgroundColor: '#1f2937', border: '1px solid #374151', borderRadius: 8 }}
                labelStyle={{ color: '#e5e7eb' }}
              />
              <Bar dataKey="tokens" fill="#1b83f5" radius={[4, 4, 0, 0]} />
            </BarChart>
          </ResponsiveContainer>
        </div>

        <div className="card">
          <h3 className="text-sm font-medium text-gray-400 mb-4">Model Tier Distribution</h3>
          <ResponsiveContainer width="100%" height={200}>
            <PieChart>
              <Pie
                data={modelDistribution}
                cx="50%"
                cy="50%"
                innerRadius={50}
                outerRadius={80}
                dataKey="value"
                label={({ name, percent }) => `${name} ${(percent * 100).toFixed(0)}%`}
              >
                {modelDistribution.map((entry) => (
                  <Cell key={entry.name} fill={MODEL_COLORS[entry.name] || '#6b7280'} />
                ))}
              </Pie>
              <Tooltip
                contentStyle={{ backgroundColor: '#1f2937', border: '1px solid #374151', borderRadius: 8 }}
              />
            </PieChart>
          </ResponsiveContainer>
        </div>
      </div>

      {/* Tabs */}
      <div className="border-b border-gray-800 mb-6">
        <div className="flex gap-6">
          {[
            { key: 'messages' as const, label: 'Recent Messages', icon: MessageSquare },
            { key: 'soul' as const, label: 'SOUL.md', icon: Brain },
            { key: 'memory' as const, label: 'MEMORY.md', icon: FileText },
          ].map((tab) => (
            <button
              key={tab.key}
              onClick={() => setActiveTab(tab.key)}
              className={`flex items-center gap-2 pb-3 px-1 text-sm font-medium border-b-2 transition-colors ${
                activeTab === tab.key
                  ? 'text-hydra-400 border-hydra-400'
                  : 'text-gray-500 border-transparent hover:text-gray-300'
              }`}
            >
              <tab.icon className="w-4 h-4" />
              {tab.label}
            </button>
          ))}
        </div>
      </div>

      {/* Tab content */}
      {activeTab === 'messages' && (
        <div className="space-y-3">
          {messages.length === 0 ? (
            <div className="card text-center text-gray-500 py-12">
              No messages recorded yet
            </div>
          ) : (
            messages.map((msg) => (
              <div key={msg.id} className="card">
                <div className="flex items-center justify-between mb-2">
                  <div className="flex items-center gap-3">
                    <span className="badge-blue">{msg.channel}</span>
                    {msg.crossAgent && <span className="badge-yellow">cross-agent</span>}
                  </div>
                  <div className="flex items-center gap-4 text-xs text-gray-500">
                    <span className="flex items-center gap-1">
                      <Zap className="w-3 h-3" />
                      {msg.tokensUsed.toLocaleString()} tokens
                    </span>
                    <span className="flex items-center gap-1">
                      <Clock className="w-3 h-3" />
                      {new Date(msg.timestamp).toLocaleString()}
                    </span>
                  </div>
                </div>
                <p className="text-sm text-gray-300">{msg.content}</p>
                {msg.toolsInvoked.length > 0 && (
                  <div className="mt-2 flex gap-1 flex-wrap">
                    {msg.toolsInvoked.map((tool) => (
                      <span key={tool} className="text-xs px-2 py-0.5 bg-gray-800 rounded text-gray-400">
                        {tool}
                      </span>
                    ))}
                  </div>
                )}
              </div>
            ))
          )}
        </div>
      )}

      {activeTab === 'soul' && (
        <div className="card">
          <h3 className="text-sm font-medium text-gray-400 mb-4">SOUL.md</h3>
          <pre className="text-sm text-gray-300 whitespace-pre-wrap font-mono bg-gray-950 p-4 rounded-lg border border-gray-800 max-h-[600px] overflow-y-auto">
            {agent?.soulMd || 'No SOUL.md content available'}
          </pre>
        </div>
      )}

      {activeTab === 'memory' && (
        <div className="space-y-4">
          <div className="card">
            <h3 className="text-sm font-medium text-gray-400 mb-4">Current MEMORY.md</h3>
            <pre className="text-sm text-gray-300 whitespace-pre-wrap font-mono bg-gray-950 p-4 rounded-lg border border-gray-800 max-h-[400px] overflow-y-auto">
              {agent?.memoryMd || 'No MEMORY.md content available'}
            </pre>
          </div>

          <div className="card">
            <h3 className="text-sm font-medium text-gray-400 mb-4">Version History</h3>
            {agent?.memoryVersions && agent.memoryVersions.length > 0 ? (
              <div className="space-y-2">
                {agent.memoryVersions.map((v) => (
                  <div key={v.version} className="p-3 bg-gray-950 rounded-lg border border-gray-800">
                    <div className="flex items-center justify-between mb-2">
                      <span className="text-sm font-medium text-gray-300">v{v.version}</span>
                      <span className="text-xs text-gray-500">{new Date(v.timestamp).toLocaleString()}</span>
                    </div>
                    <pre className="text-xs text-gray-400 whitespace-pre-wrap font-mono">{v.diff}</pre>
                  </div>
                ))}
              </div>
            ) : (
              <p className="text-sm text-gray-500">No version history available</p>
            )}
          </div>
        </div>
      )}
    </div>
  );
}
