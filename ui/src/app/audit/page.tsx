'use client';

import { useEffect, useState, useCallback } from 'react';
import {
  FileText,
  Search,
  Filter,
  Clock,
  Zap,
  ArrowLeftRight,
  ChevronLeft,
  ChevronRight,
} from 'lucide-react';
import type { AuditEntry } from '@/lib/api';

const AGENTS = ['all', 'coordinator', 'ceo', 'cto', 'cmo', 'devops', 'finance', 'design', 'operations', 'qa'];
const PAGE_SIZE = 50;

export default function AuditPage() {
  const [entries, setEntries] = useState<AuditEntry[]>([]);
  const [loading, setLoading] = useState(true);
  const [agentFilter, setAgentFilter] = useState('all');
  const [searchQuery, setSearchQuery] = useState('');
  const [dateFrom, setDateFrom] = useState('');
  const [dateTo, setDateTo] = useState('');
  const [toolFilter, setToolFilter] = useState('');
  const [crossAgentOnly, setCrossAgentOnly] = useState(false);
  const [offset, setOffset] = useState(0);

  const fetchAudit = useCallback(async () => {
    setLoading(true);
    try {
      const params = new URLSearchParams();
      if (agentFilter !== 'all') params.set('agent', agentFilter);
      if (dateFrom) params.set('from', dateFrom);
      if (dateTo) params.set('to', dateTo);
      if (toolFilter) params.set('tool', toolFilter);
      if (crossAgentOnly) params.set('crossAgent', 'true');
      params.set('limit', String(PAGE_SIZE));
      params.set('offset', String(offset));

      const res = await fetch(`/api/audit?${params.toString()}`);
      if (res.ok) {
        setEntries(await res.json());
      }
    } catch {
      // handle error
    } finally {
      setLoading(false);
    }
  }, [agentFilter, dateFrom, dateTo, toolFilter, crossAgentOnly, offset]);

  useEffect(() => {
    fetchAudit();
  }, [fetchAudit]);

  const filtered = entries.filter((e) => {
    if (searchQuery) {
      const q = searchQuery.toLowerCase();
      return (
        e.messagePreview.toLowerCase().includes(q) ||
        e.agentName.toLowerCase().includes(q) ||
        e.action.toLowerCase().includes(q)
      );
    }
    return true;
  });

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-white flex items-center gap-3">
          <FileText className="w-7 h-7 text-hydra-400" />
          Audit Log
        </h1>
        <p className="text-gray-500 mt-1">Searchable log of all agent interactions</p>
      </div>

      {/* Filters */}
      <div className="card mb-6">
        <div className="flex items-center gap-2 mb-4">
          <Filter className="w-4 h-4 text-gray-400" />
          <span className="text-sm font-medium text-gray-400">Filters</span>
        </div>
        <div className="grid grid-cols-1 md:grid-cols-6 gap-3">
          <div className="md:col-span-2">
            <div className="relative">
              <Search className="w-4 h-4 text-gray-500 absolute left-3 top-1/2 -translate-y-1/2" />
              <input
                type="text"
                value={searchQuery}
                onChange={(e) => setSearchQuery(e.target.value)}
                placeholder="Search messages..."
                className="w-full bg-gray-950 border border-gray-700 rounded-lg pl-10 pr-3 py-2 text-sm text-gray-200 placeholder-gray-600 focus:border-hydra-500 focus:ring-1 focus:ring-hydra-500"
              />
            </div>
          </div>

          <select
            value={agentFilter}
            onChange={(e) => { setAgentFilter(e.target.value); setOffset(0); }}
            className="bg-gray-950 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200 focus:border-hydra-500 focus:ring-1 focus:ring-hydra-500"
          >
            {AGENTS.map((a) => (
              <option key={a} value={a}>{a === 'all' ? 'All agents' : a}</option>
            ))}
          </select>

          <input
            type="date"
            value={dateFrom}
            onChange={(e) => { setDateFrom(e.target.value); setOffset(0); }}
            placeholder="From"
            className="bg-gray-950 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200 focus:border-hydra-500 focus:ring-1 focus:ring-hydra-500"
          />

          <input
            type="date"
            value={dateTo}
            onChange={(e) => { setDateTo(e.target.value); setOffset(0); }}
            placeholder="To"
            className="bg-gray-950 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200 focus:border-hydra-500 focus:ring-1 focus:ring-hydra-500"
          />

          <div className="flex items-center gap-2">
            <label className="flex items-center gap-2 text-sm text-gray-400 cursor-pointer">
              <input
                type="checkbox"
                checked={crossAgentOnly}
                onChange={(e) => { setCrossAgentOnly(e.target.checked); setOffset(0); }}
                className="rounded bg-gray-950 border-gray-700 text-hydra-500 focus:ring-hydra-500"
              />
              Cross-agent only
            </label>
          </div>
        </div>

        <div className="mt-3">
          <input
            type="text"
            value={toolFilter}
            onChange={(e) => { setToolFilter(e.target.value); setOffset(0); }}
            placeholder="Filter by tool (e.g. Bash, Write)"
            className="bg-gray-950 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200 placeholder-gray-600 focus:border-hydra-500 focus:ring-1 focus:ring-hydra-500 w-full md:w-64"
          />
        </div>
      </div>

      {/* Results */}
      {loading ? (
        <div className="space-y-3">
          {Array.from({ length: 10 }).map((_, i) => (
            <div key={i} className="card animate-pulse">
              <div className="h-4 bg-gray-800 rounded w-3/4 mb-2" />
              <div className="h-3 bg-gray-800 rounded w-1/2" />
            </div>
          ))}
        </div>
      ) : filtered.length === 0 ? (
        <div className="card text-center text-gray-500 py-12">
          No audit entries found matching your filters
        </div>
      ) : (
        <>
          <div className="space-y-2">
            {filtered.map((entry) => (
              <div key={entry.id} className="card hover:border-gray-700 transition-colors">
                <div className="flex items-start justify-between">
                  <div className="flex-1 min-w-0">
                    <div className="flex items-center gap-2 mb-1">
                      <span className="badge-blue">{entry.agentName}</span>
                      <span className="text-xs text-gray-600">{entry.channel}</span>
                      {entry.crossAgent && (
                        <span className="badge-yellow flex items-center gap-1">
                          <ArrowLeftRight className="w-3 h-3" />
                          cross-agent
                        </span>
                      )}
                    </div>
                    <p className="text-sm text-gray-300 truncate">{entry.messagePreview}</p>
                    {entry.toolsInvoked.length > 0 && (
                      <div className="mt-1 flex gap-1 flex-wrap">
                        {entry.toolsInvoked.map((tool) => (
                          <span key={tool} className="text-xs px-1.5 py-0.5 bg-gray-800 rounded text-gray-500">
                            {tool}
                          </span>
                        ))}
                      </div>
                    )}
                  </div>
                  <div className="flex flex-col items-end gap-1 ml-4 flex-shrink-0">
                    <span className="text-xs text-gray-500 flex items-center gap-1">
                      <Clock className="w-3 h-3" />
                      {new Date(entry.timestamp).toLocaleString()}
                    </span>
                    <span className="text-xs text-gray-600 flex items-center gap-1">
                      <Zap className="w-3 h-3" />
                      {entry.tokensUsed.toLocaleString()} tokens
                    </span>
                  </div>
                </div>
              </div>
            ))}
          </div>

          {/* Pagination */}
          <div className="flex items-center justify-between mt-6">
            <p className="text-sm text-gray-500">
              Showing {offset + 1}-{offset + filtered.length} entries
            </p>
            <div className="flex gap-2">
              <button
                onClick={() => setOffset(Math.max(0, offset - PAGE_SIZE))}
                disabled={offset === 0}
                className="btn-secondary flex items-center gap-1 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                <ChevronLeft className="w-4 h-4" />
                Previous
              </button>
              <button
                onClick={() => setOffset(offset + PAGE_SIZE)}
                disabled={filtered.length < PAGE_SIZE}
                className="btn-secondary flex items-center gap-1 disabled:opacity-50 disabled:cursor-not-allowed"
              >
                Next
                <ChevronRight className="w-4 h-4" />
              </button>
            </div>
          </div>
        </>
      )}
    </div>
  );
}
