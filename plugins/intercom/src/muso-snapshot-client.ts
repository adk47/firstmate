import type { AccountSnapshot } from "./types.js";
import type { SnapshotLookup } from "./enrichment.js";

// Minimal, GET-only Muso admin client for personalization enrichment.
//
// Deliberately a small copy of the security envelope in
// plugins/support-tools/src/muso-admin-client.ts — the two plugins are
// separate npm packages and cannot share runtime code without a shared
// package. KEEP THE ALLOWLIST IN SYNC with that file. This client adds nothing
// the support-tools one lacks; it only drops the HttpClient abstraction in
// favor of native fetch + per-call AbortSignal timeouts.
const ALLOWED_PATHS: RegExp[] = [
  /^\/api\/v3\/admin\/profile\/search(\?|$)/,
  /^\/api\/v3\/admin\/profile\/[0-9a-fA-F-]+(\?|$)/,
  /^\/api\/v3\/admin\/profile\/[0-9a-fA-F-]+\/credits(\?|$)/,
];

const TOKEN_TTL_MS = 22 * 60 * 60 * 1000; // refresh 1h before the 23h server cache expires

type FetchImpl = (url: string, init?: any) => Promise<{
  ok: boolean;
  status: number;
  json: () => Promise<any>;
}>;

export interface SnapshotClientDeps {
  musoApiBase: string;
  adminEmail: string;
  adminPassword: string;
  fetchImpl?: FetchImpl;
  log?: { warn?: (m: string) => void };
}

export function createSnapshotClient(deps: SnapshotClientDeps): { lookupSnapshot: SnapshotLookup } {
  const doFetch: FetchImpl = deps.fetchImpl ?? (globalThis.fetch as unknown as FetchImpl);
  let cachedToken: string | null = null;
  let cachedAt = 0;

  async function login(timeoutMs: number): Promise<string> {
    const resp = await doFetch(`${deps.musoApiBase}/api/v3/admin/user/login`, {
      method: "POST",
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: JSON.stringify({ email: deps.adminEmail, password: deps.adminPassword }),
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (!resp.ok) throw new Error(`admin login failed: HTTP ${resp.status}`);
    const data = await resp.json();
    const tok =
      data?.data?.authentication?.accessToken ??
      data?.data?.user?.accessToken ??
      data?.token ??
      "";
    if (!tok) throw new Error("admin login returned no token");
    return tok;
  }

  async function getToken(timeoutMs: number): Promise<string> {
    const now = Date.now();
    if (cachedToken && now - cachedAt < TOKEN_TTL_MS) return cachedToken;
    const fresh = await login(timeoutMs);
    cachedToken = fresh;
    cachedAt = now;
    return fresh;
  }

  function assertAllowed(path: string): void {
    if (!path.startsWith("/api/v3/admin/") || path.includes("..") || !ALLOWED_PATHS.some((re) => re.test(path))) {
      throw new Error(`path not allowlisted: ${path}`);
    }
  }

  async function get<T>(path: string, timeoutMs: number, retried = false): Promise<{ ok: boolean; status: number; data?: T }> {
    assertAllowed(path);
    const token = await getToken(timeoutMs);
    const resp = await doFetch(`${deps.musoApiBase}${path}`, {
      method: "GET",
      headers: { Authorization: `Bearer ${token}`, Service: "caroline", Accept: "application/json" },
      signal: AbortSignal.timeout(timeoutMs),
    });
    if (resp.ok) return { ok: true, status: 200, data: (await resp.json()) as T };
    // Token likely expired server-side before our TTL — refresh once and retry.
    if (resp.status === 401 && !retried) {
      cachedToken = null;
      return get<T>(path, timeoutMs, true);
    }
    return { ok: false, status: resp.status };
  }

  async function lookupSnapshot(email: string, opts: { timeoutMs: number }): Promise<AccountSnapshot | null> {
    const { timeoutMs } = opts;
    try {
      const searchResp = await get<{ data?: Record<string, unknown>[] }>(
        `/api/v3/admin/profile/search?keyword=${encodeURIComponent(email)}&limit=5`,
        timeoutMs,
      );
      if (!searchResp.ok) return null;
      const results = searchResp.data?.data ?? [];
      // 0 = no match, >1 = ambiguous — never guess which artist.
      if (results.length !== 1) return null;
      const row = results[0];
      // /profile/search is a keyword search, so a lone result can still be a
      // fuzzy (non-email) match. Require the row's email to exactly match the
      // verified Intercom email before trusting it — otherwise we'd attach the
      // wrong person's profile/credits. (The email itself is never copied into
      // the snapshot below; it's only the match gate.)
      const rowEmail = String(row.email ?? "").trim().toLowerCase();
      if (!rowEmail || rowEmail !== email.trim().toLowerCase()) return null;
      const profileId = String(row.id ?? "");
      if (!profileId) return null;

      const credResp = await get<{ data?: { items?: Record<string, unknown>[] } }>(
        `/api/v3/admin/profile/${encodeURIComponent(profileId)}/credits?limit=20&offset=0`,
        timeoutMs,
      );
      const items = credResp.ok ? credResp.data?.data?.items ?? [] : [];
      const latest = items
        .map((it) => ({ title: String(it.title ?? ""), date: String(it.releaseDate ?? "") }))
        .filter((c) => c.date)
        .sort((a, b) => b.date.localeCompare(a.date))[0];

      const cc = row.commonCredits;
      const primaryRole =
        Array.isArray(cc) && cc.length > 0
          ? String(cc[0])
          : String(row.role ?? row.primaryRole ?? "") || undefined;

      // Assemble ONLY the fields we want — this is what strips PII: email/phone/
      // payment on the search row are never copied across.
      return {
        profileId,
        name: String(row.name ?? "") || undefined,
        profileUrl: `https://muso.ai/profile/${profileId}`,
        isClaimed: Boolean(row.isClaimed),
        ...(primaryRole ? { primaryRole } : {}),
        creditsCount: Number(row.creditCount ?? row.creditsCount ?? 0),
        ...(latest?.title ? { latestCreditTitle: latest.title } : {}),
        ...(latest?.date ? { latestCreditDate: latest.date } : {}),
      };
    } catch (err) {
      deps.log?.warn?.(`[intercom] snapshot lookup error: ${err}`);
      return null;
    }
  }

  return { lookupSnapshot };
}
