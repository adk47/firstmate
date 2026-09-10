// openclaw@2026.8.1 ships this subpath's JS without type declarations (exports
// verified identical to 7.1); remove this shim when upstream restores the .d.ts.
declare module "openclaw/plugin-sdk/memory-host-search" {
  /** A single memory-search hit, as returned by MemorySearchManager.search(). */
  interface MemorySearchHit {
    path: string;
    startLine?: number;
    endLine?: number;
    score: number;
    snippet: string;
    source?: string;
    [key: string]: unknown;
  }

  /** The subset of the openclaw memory-search manager consumed by callers of this module. */
  interface MemorySearchManagerLike {
    search(
      query: string,
      opts?: {
        maxResults?: number;
        minScore?: number;
        sessionKey?: string;
        lexicalOnly?: boolean;
        activeProjectKeys?: string[];
        sources?: string[];
        signal?: AbortSignal;
      },
    ): Promise<MemorySearchHit[]>;
  }

  function getActiveMemorySearchManager(params: {
    cfg: unknown;
    agentId: string;
    purpose?: "default" | "status" | "cli";
    inspectSources?: boolean;
  }): Promise<{
    manager: MemorySearchManagerLike | null;
    debug?: unknown;
    error?: string;
  }>;

  function closeActiveMemorySearchManager(agentId: string): Promise<void>;
  function closeActiveMemorySearchManagers(): Promise<void>;
}
