'use client';

import { useEffect, useState } from 'react';
import { Shield, Plus, Trash2, GitPullRequest, Globe, AlertTriangle } from 'lucide-react';

interface DenyListEntry {
  agent: string;
  tools: string[];
}

interface EgressEntry {
  agent: string;
  allowedHosts: string[];
}

const AGENTS = ['coordinator', 'ceo', 'cto', 'cmo', 'devops', 'finance', 'design', 'operations', 'qa'];

export default function PoliciesPage() {
  const [denyLists, setDenyLists] = useState<DenyListEntry[]>([]);
  const [egressLists, setEgressLists] = useState<EgressEntry[]>([]);
  const [originalDenyLists, setOriginalDenyLists] = useState<DenyListEntry[]>([]);
  const [selectedAgent, setSelectedAgent] = useState(AGENTS[0]);
  const [newTool, setNewTool] = useState('');
  const [submitting, setSubmitting] = useState(false);
  const [prUrl, setPrUrl] = useState<string | null>(null);
  const [loading, setLoading] = useState(true);
  const [activeTab, setActiveTab] = useState<'deny' | 'egress'>('deny');

  useEffect(() => {
    async function load() {
      try {
        const res = await fetch('/api/policies/deny-lists');
        if (res.ok) {
          const data = await res.json();
          setDenyLists(data.denyLists || []);
          setOriginalDenyLists(JSON.parse(JSON.stringify(data.denyLists || [])));
          setEgressLists(data.egressLists || []);
        }
      } catch {
        // Initialize with empty lists per agent
        const empty = AGENTS.map((a) => ({ agent: a, tools: [] }));
        setDenyLists(empty);
        setOriginalDenyLists(JSON.parse(JSON.stringify(empty)));
        setEgressLists(AGENTS.map((a) => ({ agent: a, allowedHosts: [] })));
      } finally {
        setLoading(false);
      }
    }
    load();
  }, []);

  const currentAgentDeny = denyLists.find((d) => d.agent === selectedAgent);
  const originalAgentDeny = originalDenyLists.find((d) => d.agent === selectedAgent);
  const currentAgentEgress = egressLists.find((e) => e.agent === selectedAgent);

  function addTool() {
    if (!newTool.trim()) return;
    setDenyLists((prev) =>
      prev.map((d) =>
        d.agent === selectedAgent
          ? { ...d, tools: [...new Set([...d.tools, newTool.trim()])] }
          : d
      )
    );
    setNewTool('');
  }

  function removeTool(tool: string) {
    // Check if this tool was in the original list (cannot remove existing denials)
    if (originalAgentDeny?.tools.includes(tool)) {
      alert('Cannot remove existing denials. Denials can only grow, never shrink.');
      return;
    }
    setDenyLists((prev) =>
      prev.map((d) =>
        d.agent === selectedAgent
          ? { ...d, tools: d.tools.filter((t) => t !== tool) }
          : d
      )
    );
  }

  function hasChanges(): boolean {
    return JSON.stringify(denyLists) !== JSON.stringify(originalDenyLists);
  }

  function getDiff(): { agent: string; added: string[]; removed: string[] }[] {
    const diffs: { agent: string; added: string[]; removed: string[] }[] = [];
    for (const entry of denyLists) {
      const original = originalDenyLists.find((o) => o.agent === entry.agent);
      const originalTools = original?.tools || [];
      const added = entry.tools.filter((t) => !originalTools.includes(t));
      const removed = originalTools.filter((t) => !entry.tools.includes(t));
      if (added.length > 0 || removed.length > 0) {
        diffs.push({ agent: entry.agent, added, removed });
      }
    }
    return diffs;
  }

  async function createPR() {
    if (!hasChanges()) return;
    setSubmitting(true);
    try {
      const changes: Record<string, string[]> = {};
      denyLists.forEach((d) => {
        changes[d.agent] = d.tools;
      });
      const res = await fetch('/api/policies/deny-lists', {
        method: 'PUT',
        headers: { 'Content-Type': 'application/json' },
        body: JSON.stringify(changes),
      });
      const data = await res.json();
      if (data.prUrl) {
        setPrUrl(data.prUrl);
      }
    } catch {
      alert('Failed to create PR');
    } finally {
      setSubmitting(false);
    }
  }

  const diff = getDiff();

  if (loading) {
    return (
      <div className="animate-pulse space-y-6">
        <div className="h-8 bg-gray-800 rounded w-48" />
        <div className="h-96 bg-gray-800 rounded" />
      </div>
    );
  }

  return (
    <div>
      <div className="mb-8">
        <h1 className="text-2xl font-bold text-white flex items-center gap-3">
          <Shield className="w-7 h-7 text-hydra-400" />
          Governance Policies
        </h1>
        <p className="text-gray-500 mt-1">
          Manage tool deny lists and egress allowlists. Changes create a PR for review.
        </p>
      </div>

      {prUrl && (
        <div className="card border-green-800 bg-green-950/30 mb-6">
          <div className="flex items-center gap-3">
            <GitPullRequest className="w-5 h-5 text-green-400" />
            <div>
              <p className="text-sm font-medium text-green-400">PR Created</p>
              <a href={prUrl} target="_blank" rel="noopener noreferrer" className="text-sm text-hydra-400 hover:underline">
                {prUrl}
              </a>
            </div>
          </div>
        </div>
      )}

      <div className="grid grid-cols-1 md:grid-cols-4 gap-6">
        {/* Agent selector */}
        <div className="card">
          <h3 className="text-sm font-medium text-gray-400 mb-4">Agent</h3>
          <div className="space-y-1">
            {AGENTS.map((agent) => (
              <button
                key={agent}
                onClick={() => setSelectedAgent(agent)}
                className={`w-full text-left px-3 py-2 rounded-lg text-sm transition-colors ${
                  selectedAgent === agent
                    ? 'bg-hydra-700/20 text-hydra-400 border border-hydra-700'
                    : 'text-gray-400 hover:bg-gray-800 border border-transparent'
                }`}
              >
                {agent}
              </button>
            ))}
          </div>
        </div>

        {/* Policy editor */}
        <div className="md:col-span-3 space-y-6">
          {/* Tabs */}
          <div className="border-b border-gray-800">
            <div className="flex gap-6">
              <button
                onClick={() => setActiveTab('deny')}
                className={`flex items-center gap-2 pb-3 px-1 text-sm font-medium border-b-2 transition-colors ${
                  activeTab === 'deny'
                    ? 'text-hydra-400 border-hydra-400'
                    : 'text-gray-500 border-transparent hover:text-gray-300'
                }`}
              >
                <Shield className="w-4 h-4" />
                Tool Deny Lists
              </button>
              <button
                onClick={() => setActiveTab('egress')}
                className={`flex items-center gap-2 pb-3 px-1 text-sm font-medium border-b-2 transition-colors ${
                  activeTab === 'egress'
                    ? 'text-hydra-400 border-hydra-400'
                    : 'text-gray-500 border-transparent hover:text-gray-300'
                }`}
              >
                <Globe className="w-4 h-4" />
                Egress Allowlists
              </button>
            </div>
          </div>

          {activeTab === 'deny' && (
            <div className="card">
              <h3 className="text-sm font-medium text-gray-400 mb-4">
                Denied tools for <span className="text-white">{selectedAgent}</span>
              </h3>

              <div className="flex gap-2 mb-4">
                <input
                  type="text"
                  value={newTool}
                  onChange={(e) => setNewTool(e.target.value)}
                  onKeyDown={(e) => e.key === 'Enter' && addTool()}
                  placeholder="Tool name to deny (e.g. Bash, Write)"
                  className="flex-1 bg-gray-950 border border-gray-700 rounded-lg px-3 py-2 text-sm text-gray-200 placeholder-gray-600 focus:border-hydra-500 focus:ring-1 focus:ring-hydra-500"
                />
                <button onClick={addTool} className="btn-primary flex items-center gap-2">
                  <Plus className="w-4 h-4" />
                  Add
                </button>
              </div>

              <div className="space-y-2">
                {currentAgentDeny?.tools.length === 0 ? (
                  <p className="text-sm text-gray-500 py-4 text-center">
                    No denied tools for this agent
                  </p>
                ) : (
                  currentAgentDeny?.tools.map((tool) => {
                    const isOriginal = originalAgentDeny?.tools.includes(tool);
                    const isNew = !isOriginal;
                    return (
                      <div
                        key={tool}
                        className={`flex items-center justify-between px-3 py-2 rounded-lg border ${
                          isNew
                            ? 'bg-green-950/20 border-green-800'
                            : 'bg-gray-950 border-gray-800'
                        }`}
                      >
                        <div className="flex items-center gap-2">
                          <code className="text-sm text-gray-200">{tool}</code>
                          {isNew && <span className="badge-green text-xs">new</span>}
                          {isOriginal && (
                            <span className="text-xs text-gray-600">locked</span>
                          )}
                        </div>
                        <button
                          onClick={() => removeTool(tool)}
                          disabled={isOriginal}
                          className={`p-1 rounded ${
                            isOriginal
                              ? 'text-gray-700 cursor-not-allowed'
                              : 'text-red-400 hover:bg-red-900/30'
                          }`}
                        >
                          <Trash2 className="w-4 h-4" />
                        </button>
                      </div>
                    );
                  })
                )}
              </div>
            </div>
          )}

          {activeTab === 'egress' && (
            <div className="card">
              <h3 className="text-sm font-medium text-gray-400 mb-4">
                Egress allowlist for <span className="text-white">{selectedAgent}</span>
              </h3>
              <div className="space-y-2">
                {currentAgentEgress?.allowedHosts.length === 0 ? (
                  <p className="text-sm text-gray-500 py-4 text-center">
                    No egress rules configured. All external access is denied by default.
                  </p>
                ) : (
                  currentAgentEgress?.allowedHosts.map((host) => (
                    <div key={host} className="flex items-center px-3 py-2 bg-gray-950 rounded-lg border border-gray-800">
                      <Globe className="w-4 h-4 text-gray-500 mr-2" />
                      <code className="text-sm text-gray-200">{host}</code>
                    </div>
                  ))
                )}
              </div>
              <div className="mt-4 p-3 bg-yellow-950/20 border border-yellow-900 rounded-lg">
                <div className="flex items-start gap-2">
                  <AlertTriangle className="w-4 h-4 text-yellow-500 mt-0.5" />
                  <p className="text-xs text-yellow-400">
                    Egress rules can only be modified by Aaron (adk47). Contact the administrator to request changes.
                  </p>
                </div>
              </div>
            </div>
          )}

          {/* Diff preview */}
          {diff.length > 0 && (
            <div className="card border-hydra-800">
              <h3 className="text-sm font-medium text-gray-400 mb-4">Pending Changes (Diff Preview)</h3>
              <div className="space-y-3">
                {diff.map((d) => (
                  <div key={d.agent} className="p-3 bg-gray-950 rounded-lg border border-gray-800">
                    <p className="text-sm font-medium text-white mb-2">{d.agent}</p>
                    {d.added.map((t) => (
                      <p key={t} className="text-sm text-green-400 font-mono">+ {t}</p>
                    ))}
                    {d.removed.map((t) => (
                      <p key={t} className="text-sm text-red-400 font-mono">- {t}</p>
                    ))}
                  </div>
                ))}
              </div>
              <div className="mt-4 flex justify-end">
                <button
                  onClick={createPR}
                  disabled={submitting}
                  className="btn-primary flex items-center gap-2"
                >
                  <GitPullRequest className="w-4 h-4" />
                  {submitting ? 'Creating PR...' : 'Create PR'}
                </button>
              </div>
            </div>
          )}
        </div>
      </div>
    </div>
  );
}
