'use client';

import { useEffect, useState } from 'react';
import {
  DollarSign,
  TrendingUp,
  AlertTriangle,
  Bot,
  Cpu,
} from 'lucide-react';
import {
  AreaChart,
  Area,
  XAxis,
  YAxis,
  CartesianGrid,
  Tooltip,
  ResponsiveContainer,
  BarChart,
  Bar,
  PieChart,
  Pie,
  Cell,
  Legend,
} from 'recharts';
import type { CostSummary } from '@/lib/api';

const AGENT_COLORS: Record<string, string> = {
  coordinator: '#1b83f5',
  ceo: '#8b5cf6',
  cto: '#f59e0b',
  cmo: '#10b981',
  devops: '#ef4444',
  finance: '#06b6d4',
  design: '#ec4899',
  operations: '#84cc16',
  qa: '#f97316',
};

const MODEL_COLORS: Record<string, string> = {
  opus: '#1b83f5',
  sonnet: '#34d399',
  haiku: '#fbbf24',
};

export default function CostsPage() {
  const [costs, setCosts] = useState<CostSummary | null>(null);
  const [period, setPeriod] = useState<'daily' | 'monthly'>('daily');
  const [loading, setLoading] = useState(true);

  useEffect(() => {
    async function load() {
      try {
        const res = await fetch(`/api/costs?period=${period}`);
        if (res.ok) {
          setCosts(await res.json());
        }
      } catch {
        // handle error
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [period]);

  const agentChartData = costs?.byAgent
    ? Object.entries(costs.byAgent).map(([name, cost]) => ({ name, cost }))
    : [];

  const modelChartData = costs?.byModel
    ? Object.entries(costs.byModel).map(([name, cost]) => ({ name, cost }))
    : [];

  // Generate trend data from daily entries
  const trendData = costs?.daily?.reduce<Record<string, { date: string; cost: number }>>(
    (acc, entry) => {
      if (!acc[entry.date]) acc[entry.date] = { date: entry.date, cost: 0 };
      acc[entry.date].cost += entry.totalCost;
      return acc;
    },
    {}
  );
  const trendChartData = trendData ? Object.values(trendData).sort((a, b) => a.date.localeCompare(b.date)) : [];

  if (loading) {
    return (
      <div className="animate-pulse space-y-6">
        <div className="h-8 bg-gray-800 rounded w-48" />
        <div className="grid grid-cols-3 gap-4">
          <div className="h-32 bg-gray-800 rounded" />
          <div className="h-32 bg-gray-800 rounded" />
          <div className="h-32 bg-gray-800 rounded" />
        </div>
        <div className="h-96 bg-gray-800 rounded" />
      </div>
    );
  }

  return (
    <div>
      <div className="flex items-center justify-between mb-8">
        <div>
          <h1 className="text-2xl font-bold text-white flex items-center gap-3">
            <DollarSign className="w-7 h-7 text-hydra-400" />
            Cost Dashboard
          </h1>
          <p className="text-gray-500 mt-1">Token usage and cost breakdown across agents and models</p>
        </div>
        <div className="flex gap-2">
          <button
            onClick={() => setPeriod('daily')}
            className={period === 'daily' ? 'btn-primary' : 'btn-secondary'}
          >
            Daily
          </button>
          <button
            onClick={() => setPeriod('monthly')}
            className={period === 'monthly' ? 'btn-primary' : 'btn-secondary'}
          >
            Monthly
          </button>
        </div>
      </div>

      {/* Summary cards */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
        <div className="card">
          <div className="flex items-center gap-2 mb-2">
            <DollarSign className="w-5 h-5 text-green-400" />
            <span className="text-sm text-gray-400">Today</span>
          </div>
          <p className="text-3xl font-bold text-white">
            ${costs?.totalToday?.toFixed(2) || '0.00'}
          </p>
        </div>
        <div className="card">
          <div className="flex items-center gap-2 mb-2">
            <TrendingUp className="w-5 h-5 text-hydra-400" />
            <span className="text-sm text-gray-400">This Month</span>
          </div>
          <p className="text-3xl font-bold text-white">
            ${costs?.totalThisMonth?.toFixed(2) || '0.00'}
          </p>
        </div>
        <div className="card">
          <div className="flex items-center gap-2 mb-2">
            <AlertTriangle className="w-5 h-5 text-yellow-400" />
            <span className="text-sm text-gray-400">Budget Alert</span>
          </div>
          <p className="text-sm text-gray-400 mt-2">
            Configure budget thresholds in governance policies
          </p>
        </div>
      </div>

      {/* Cost trend */}
      <div className="card mb-8">
        <h3 className="text-sm font-medium text-gray-400 mb-4">Cost Trend</h3>
        <ResponsiveContainer width="100%" height={300}>
          <AreaChart data={trendChartData}>
            <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
            <XAxis dataKey="date" tick={{ fill: '#9ca3af', fontSize: 12 }} />
            <YAxis tick={{ fill: '#9ca3af', fontSize: 12 }} tickFormatter={(v) => `$${v}`} />
            <Tooltip
              contentStyle={{ backgroundColor: '#1f2937', border: '1px solid #374151', borderRadius: 8 }}
              labelStyle={{ color: '#e5e7eb' }}
              formatter={(value: number) => [`$${value.toFixed(4)}`, 'Cost']}
            />
            <Area
              type="monotone"
              dataKey="cost"
              stroke="#1b83f5"
              fill="#1b83f5"
              fillOpacity={0.1}
            />
          </AreaChart>
        </ResponsiveContainer>
      </div>

      {/* Breakdown charts */}
      <div className="grid grid-cols-1 md:grid-cols-2 gap-6">
        <div className="card">
          <h3 className="text-sm font-medium text-gray-400 mb-4 flex items-center gap-2">
            <Bot className="w-4 h-4" />
            Per-Agent Breakdown
          </h3>
          <ResponsiveContainer width="100%" height={300}>
            <BarChart data={agentChartData} layout="vertical">
              <CartesianGrid strokeDasharray="3 3" stroke="#374151" />
              <XAxis type="number" tick={{ fill: '#9ca3af', fontSize: 12 }} tickFormatter={(v) => `$${v}`} />
              <YAxis dataKey="name" type="category" tick={{ fill: '#9ca3af', fontSize: 12 }} width={100} />
              <Tooltip
                contentStyle={{ backgroundColor: '#1f2937', border: '1px solid #374151', borderRadius: 8 }}
                formatter={(value: number) => [`$${value.toFixed(4)}`, 'Cost']}
              />
              <Bar dataKey="cost" radius={[0, 4, 4, 0]}>
                {agentChartData.map((entry) => (
                  <Cell key={entry.name} fill={AGENT_COLORS[entry.name] || '#6b7280'} />
                ))}
              </Bar>
            </BarChart>
          </ResponsiveContainer>
        </div>

        <div className="card">
          <h3 className="text-sm font-medium text-gray-400 mb-4 flex items-center gap-2">
            <Cpu className="w-4 h-4" />
            Per-Model Breakdown
          </h3>
          <ResponsiveContainer width="100%" height={300}>
            <PieChart>
              <Pie
                data={modelChartData}
                cx="50%"
                cy="50%"
                innerRadius={60}
                outerRadius={100}
                dataKey="cost"
                label={({ name, percent }) => `${name} ${(percent * 100).toFixed(0)}%`}
              >
                {modelChartData.map((entry) => (
                  <Cell key={entry.name} fill={MODEL_COLORS[entry.name] || '#6b7280'} />
                ))}
              </Pie>
              <Tooltip
                contentStyle={{ backgroundColor: '#1f2937', border: '1px solid #374151', borderRadius: 8 }}
                formatter={(value: number) => [`$${value.toFixed(4)}`, 'Cost']}
              />
              <Legend
                formatter={(value) => <span className="text-gray-400 text-sm">{value}</span>}
              />
            </PieChart>
          </ResponsiveContainer>
        </div>
      </div>
    </div>
  );
}
