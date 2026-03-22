'use client';

import { useEffect, useState } from 'react';
import {
  AlertTriangle,
  Shield,
  Zap,
  Globe,
  HeartPulse,
  Eye,
  CheckCircle2,
  Clock,
  Filter,
} from 'lucide-react';
import type { GovernanceAlert } from '@/lib/api';

const SEVERITY_STYLES: Record<string, { bg: string; border: string; icon: string; badge: string }> = {
  critical: { bg: 'bg-red-950/30', border: 'border-red-800', icon: 'text-red-400', badge: 'badge-red' },
  warning: { bg: 'bg-yellow-950/30', border: 'border-yellow-800', icon: 'text-yellow-400', badge: 'badge-yellow' },
  info: { bg: 'bg-blue-950/30', border: 'border-blue-800', icon: 'text-blue-400', badge: 'badge-blue' },
};

const TYPE_ICONS: Record<string, typeof AlertTriangle> = {
  canary_detection: Eye,
  denial_violation: Shield,
  token_spike: Zap,
  egress_violation: Globe,
  heartbeat_miss: HeartPulse,
};

const TYPE_LABELS: Record<string, string> = {
  canary_detection: 'Canary Detection',
  denial_violation: 'Denial Violation',
  token_spike: 'Token Spike',
  egress_violation: 'Egress Violation',
  heartbeat_miss: 'Heartbeat Miss',
};

export default function AlertsPage() {
  const [alerts, setAlerts] = useState<GovernanceAlert[]>([]);
  const [loading, setLoading] = useState(true);
  const [showAcknowledged, setShowAcknowledged] = useState(false);
  const [severityFilter, setSeverityFilter] = useState<string>('all');
  const [typeFilter, setTypeFilter] = useState<string>('all');

  useEffect(() => {
    async function load() {
      try {
        const params = new URLSearchParams();
        if (!showAcknowledged) params.set('acknowledged', 'false');
        const res = await fetch(`/api/alerts?${params.toString()}`);
        if (res.ok) {
          setAlerts(await res.json());
        }
      } catch {
        // handle error
      } finally {
        setLoading(false);
      }
    }
    load();
  }, [showAcknowledged]);

  async function acknowledgeAlert(id: string) {
    try {
      await fetch('/api/alerts', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id, acknowledged: true }),
      });
      setAlerts((prev) =>
        prev.map((a) => (a.id === id ? { ...a, acknowledged: true } : a))
      );
    } catch {
      // handle error
    }
  }

  async function resolveAlert(id: string) {
    try {
      await fetch('/api/alerts', {
        method: 'PATCH',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify({ id, resolved: true }),
      });
      setAlerts((prev) =>
        prev.map((a) =>
          a.id === id ? { ...a, resolvedAt: new Date().toISOString() } : a
        )
      );
    } catch {
      // handle error
    }
  }

  const filtered = alerts.filter((a) => {
    if (severityFilter !== 'all' && a.severity !== severityFilter) return false;
    if (typeFilter !== 'all' && a.type !== typeFilter) return false;
    return true;
  });

  const criticalCount = alerts.filter((a) => a.severity === 'critical' && !a.acknowledged).length;
  const warningCount = alerts.filter((a) => a.severity === 'warning' && !a.acknowledged).length;
  const totalUnresolved = alerts.filter((a) => !a.resolvedAt).length;

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-white flex items-center gap-3">
          <AlertTriangle className="w-7 h-7 text-hydra-400" />
          Governance Alerts
        </h1>
        <p className="text-gray-500 mt-1">Real-time security and governance alert monitoring</p>
      </div>

      {/* Summary */}
      <div className="grid grid-cols-1 md:grid-cols-3 gap-4 mb-8">
        <div className="card border-red-900">
          <div className="flex items-center gap-2 mb-1">
            <AlertTriangle className="w-4 h-4 text-red-400" />
            <span className="text-sm text-gray-400">Critical</span>
          </div>
          <p className="text-3xl font-bold text-red-400">{criticalCount}</p>
          <p className="text-xs text-gray-600">unacknowledged</p>
        </div>
        <div className="card border-yellow-900">
          <div className="flex items-center gap-2 mb-1">
            <AlertTriangle className="w-4 h-4 text-yellow-400" />
            <span className="text-sm text-gray-400">Warnings</span>
          </div>
          <p className="text-3xl font-bold text-yellow-400">{warningCount}</p>
          <p className="text-xs text-gray-600">unacknowledged</p>
        </div>
        <div className="card">
          <div className="flex items-center gap-2 mb-1">
            <Clock className="w-4 h-4 text-gray-400" />
            <span className="text-sm text-gray-400">Unresolved</span>
          </div>
          <p className="text-3xl font-bold text-white">{totalUnresolved}</p>
          <p className="text-xs text-gray-600">total</p>
        </div>
      </div>

      {/* Filters */}
      <div className="card mb-6">
        <div className="flex items-center gap-4 flex-wrap">
          <div className="flex items-center gap-2">
            <Filter className="w-4 h-4 text-gray-400" />
            <span className="text-sm text-gray-400">Filter:</span>
          </div>

          <select
            value={severityFilter}
            onChange={(e) => setSeverityFilter(e.target.value)}
            className="bg-gray-950 border border-gray-700 rounded-lg px-3 py-1.5 text-sm text-gray-200 focus:border-hydra-500 focus:ring-1 focus:ring-hydra-500"
          >
            <option value="all">All severities</option>
            <option value="critical">Critical</option>
            <option value="warning">Warning</option>
            <option value="info">Info</option>
          </select>

          <select
            value={typeFilter}
            onChange={(e) => setTypeFilter(e.target.value)}
            className="bg-gray-950 border border-gray-700 rounded-lg px-3 py-1.5 text-sm text-gray-200 focus:border-hydra-500 focus:ring-1 focus:ring-hydra-500"
          >
            <option value="all">All types</option>
            <option value="canary_detection">Canary Detection</option>
            <option value="denial_violation">Denial Violation</option>
            <option value="token_spike">Token Spike</option>
            <option value="egress_violation">Egress Violation</option>
            <option value="heartbeat_miss">Heartbeat Miss</option>
          </select>

          <label className="flex items-center gap-2 text-sm text-gray-400 cursor-pointer">
            <input
              type="checkbox"
              checked={showAcknowledged}
              onChange={(e) => setShowAcknowledged(e.target.checked)}
              className="rounded bg-gray-950 border-gray-700 text-hydra-500 focus:ring-hydra-500"
            />
            Show acknowledged
          </label>
        </div>
      </div>

      {/* Alert list */}
      {loading ? (
        <div className="space-y-3">
          {Array.from({ length: 5 }).map((_, i) => (
            <div key={i} className="card animate-pulse">
              <div className="h-5 bg-gray-800 rounded w-2/3 mb-2" />
              <div className="h-4 bg-gray-800 rounded w-1/2" />
            </div>
          ))}
        </div>
      ) : filtered.length === 0 ? (
        <div className="card text-center py-12">
          <CheckCircle2 className="w-12 h-12 text-green-400 mx-auto mb-4" />
          <p className="text-gray-400">No alerts matching your filters</p>
        </div>
      ) : (
        <div className="space-y-3">
          {filtered.map((alert) => {
            const style = SEVERITY_STYLES[alert.severity] || SEVERITY_STYLES.info;
            const Icon = TYPE_ICONS[alert.type] || AlertTriangle;
            return (
              <div key={alert.id} className={`card ${style.bg} ${style.border}`}>
                <div className="flex items-start justify-between">
                  <div className="flex items-start gap-3 flex-1">
                    <Icon className={`w-5 h-5 mt-0.5 ${style.icon}`} />
                    <div className="flex-1 min-w-0">
                      <div className="flex items-center gap-2 mb-1">
                        <span className={style.badge}>{alert.severity}</span>
                        <span className="text-xs text-gray-500">{TYPE_LABELS[alert.type] || alert.type}</span>
                        <span className="badge-blue">{alert.agentName}</span>
                        {alert.acknowledged && (
                          <span className="text-xs text-gray-600">acknowledged</span>
                        )}
                        {alert.resolvedAt && (
                          <span className="badge-green">resolved</span>
                        )}
                      </div>
                      <p className="text-sm text-gray-300">{alert.message}</p>
                      <p className="text-xs text-gray-600 mt-1">
                        {new Date(alert.timestamp).toLocaleString()}
                      </p>
                    </div>
                  </div>

                  <div className="flex gap-2 ml-4 flex-shrink-0">
                    {!alert.acknowledged && (
                      <button
                        onClick={() => acknowledgeAlert(alert.id)}
                        className="btn-secondary text-xs py-1 px-2"
                      >
                        Acknowledge
                      </button>
                    )}
                    {!alert.resolvedAt && (
                      <button
                        onClick={() => resolveAlert(alert.id)}
                        className="btn-primary text-xs py-1 px-2"
                      >
                        Resolve
                      </button>
                    )}
                  </div>
                </div>
              </div>
            );
          })}
        </div>
      )}
    </div>
  );
}
