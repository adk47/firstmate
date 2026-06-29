import type { AccountSnapshot } from "./types.js";
import type { SnapshotLookup } from "./enrichment.js";

// Minimal, GET-only Muso admin client for personalization enrichment.
//
// Same security envelope style as plugins/support-tools/src/muso-admin-client.ts
// (separate npm packages — runtime code can't be shared), but the allowlists
// intentionally DIVERGE: this client resolves a verified customer's email via
// /admin/claiming (email → claimed profileId) and /admin/team (founder + plan),
// which the agent-invoked support-tools client must NOT gain. profile/search is
// deliberately ABSENT here — it's a name/catalog text search, not email-indexed,
// so searching it by email can only produce nothing or a wrong-person fuzzy hit
// (the Phase-1 bug: every live enrichment returned a null snapshot).
// CI pins this list: pr-validate.yml "snapshot client path allowlist pin".
const ALLOWED_PATHS: RegExp[] = [
  /^\/api\/v3\/admin\/claiming(\?|$)/,
  /^\/api\/v3\/admin\/team(\?|$)/,
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

  // Share one in-flight login between concurrent callers — the claiming and
  // team legs run in parallel, and without this each would dogpile its own
  // login on a cold cache.
  let loginInFlight: Promise<string> | null = null;

  async function getToken(timeoutMs: number): Promise<string> {
    const now = Date.now();
    if (cachedToken && now - cachedAt < TOKEN_TTL_MS) return cachedToken;
    if (!loginInFlight) {
      loginInFlight = login(timeoutMs)
        .then((fresh) => {
          cachedToken = fresh;
          cachedAt = Date.now();
          return fresh;
        })
        .finally(() => {
          loginInFlight = null;
        });
    }
    return loginInFlight;
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

  // Both list endpoints wrap their payload in an outer `data` on the wire
  // ({ data: { items, total } }); tolerate an unwrapped { items } too so an
  // envelope change degrades to "still works" rather than silent nulls.
  function listItems(body: unknown): Record<string, unknown>[] {
    const b = body as Record<string, any> | undefined;
    const items = b?.data?.items ?? b?.items;
    return Array.isArray(items) ? items : [];
  }

  // allSettled isolates the parallel legs but also swallows their throws —
  // the outer catch in lookupSnapshot never sees them. Surface any rejection
  // (login failure, network error, abort) so an auth/API outage stays visible
  // instead of silently degrading to a null/partial snapshot.
  function warnRejected(leg: string, res: PromiseSettledResult<unknown>): void {
    if (res.status === "rejected") {
      deps.log?.warn?.(`[intercom] snapshot ${leg} fetch failed: ${res.reason}`);
    }
  }

  // /admin/claiming?keyword= → the verified customer's claimed profileId.
  // keyword is an iLike fuzzy search (joined team.email), so we gate on EXACT
  // team-email equality and status='processed'; >1 distinct profileId after
  // that = ambiguous → never guess which artist.
  async function resolveClaimedProfileId(email: string, timeoutMs: number): Promise<string | undefined> {
    const resp = await get<unknown>(
      `/api/v3/admin/claiming?keyword=${encodeURIComponent(email)}&limit=10`,
      timeoutMs,
    );
    if (!resp.ok) return undefined;
    const wanted = email.trim().toLowerCase();
    const ids = new Set<string>();
    for (const row of listItems(resp.data)) {
      if (String(row.status ?? "") !== "processed") continue;
      const teamEmail = String((row.team as Record<string, unknown> | undefined)?.email ?? "")
        .trim()
        .toLowerCase();
      if (!teamEmail || teamEmail !== wanted) continue;
      const pid = String(row.profileId ?? "");
      if (pid) ids.add(pid);
    }
    return ids.size === 1 ? [...ids][0] : undefined;
  }

  // subscription.plan arrives as a raw billing id in the wild (live 2026-06-10:
  // "muso_team_pro_graduated_monthly"), not the clean vip|business|pro|lite
  // enum the admin filters use. Reduce it to the tier token so the internal
  // billing id never reaches the agent context; unknown ids → undefined (omit
  // the plan line entirely rather than leak the raw string). Tokenized on
  // non-letters; tie-break by tier rank, highest first.
  const PLAN_TIERS = ["vip", "business", "pro", "lite"] as const;
  function normalizePlanTier(rawPlan: string): string | undefined {
    const tokens = new Set(rawPlan.toLowerCase().split(/[^a-z]+/));
    return PLAN_TIERS.find((tier) => tokens.has(tier));
  }

  // /admin/team?email= → founding-member status, workspace name, and
  // subscription plan for the verified customer's workspace. email param is
  // iLike, so exact-match gate; exactly one exact match or we surface nothing.
  // Live /admin/team row (verified 2026-06-26) carries:
  //   { id, email, name, createdAt, isDefault, isClaimed, logoUrl, coupons,
  //     stripeCustomerId, founder: {active, sinceYear, lapsedAt},
  //     subscription: {period, starDate, status, plan?} }
  // We assemble ONLY name (filtered) + founder + plan — which is what keeps
  // email/stripeCustomerId/logoUrl out of the snapshot. (createdAt year is NOT
  // surfaced: across the live founder cohort it equals founder.sinceYear, so the
  // existing "founding member: since <year>" already conveys true tenure.)
  async function resolveTeamFacts(
    email: string,
    timeoutMs: number,
  ): Promise<{ founderSince?: number; accountName?: string; plan?: string }> {
    const resp = await get<unknown>(
      `/api/v3/admin/team?email=${encodeURIComponent(email)}&limit=10`,
      timeoutMs,
    );
    if (!resp.ok) return {};
    const wanted = email.trim().toLowerCase();
    const exact = listItems(resp.data).filter(
      (row) => String(row.email ?? "").trim().toLowerCase() === wanted,
    );
    if (exact.length !== 1) return {};
    const team = exact[0];
    const founder = team.founder as Record<string, unknown> | undefined;
    const sub = team.subscription as Record<string, unknown> | undefined;
    // The API may return { active: true, sinceYear: null } when since_year is
    // missing — Number(null) is 0, which would render "since 0". Require an
    // actual numeric year.
    const sinceYear = founder?.sinceYear;
    const planTier = normalizePlanTier(String(sub?.plan ?? ""));
    const period = String(sub?.period ?? "");
    // Workspace recognition is a founder-only touch — gated here at the source so
    // non-founder behaviour is unchanged regardless of doctrine.
    const isActiveFounder = founder?.active === true;
    // team.name is auto-generated as "<Person>'s Workspace" for the default
    // personal workspace (verified live). That reads robotically as a greeting,
    // so suppress it — only a renamed/org/label workspace name is a useful
    // recognition hook; individuals fall back to the first-name greeting.
    const rawName = String(team.name ?? "").trim();
    const isAutoWorkspaceName = /['’]s workspace$/i.test(rawName);
    return {
      // Active founders only — a lapsed founder is rendered as a normal customer.
      ...(isActiveFounder && typeof sinceYear === "number" && Number.isFinite(sinceYear)
        ? { founderSince: sinceYear }
        : {}),
      ...(isActiveFounder && rawName && !isAutoWorkspaceName ? { accountName: rawName } : {}),
      ...(planTier ? { plan: period ? `${planTier} (${period})` : planTier } : {}),
    };
  }

  // profileId → public work fields (name, claimed flag, credit count, latest
  // release). Best-effort: a failed detail/credits fetch degrades to fewer
  // fields, never an error.
  async function fetchWorkFields(profileId: string, timeoutMs: number): Promise<Partial<AccountSnapshot>> {
    const [profResp, credResp] = await Promise.allSettled([
      get<{ data?: Record<string, unknown> }>(
        `/api/v3/admin/profile/${encodeURIComponent(profileId)}`,
        timeoutMs,
      ),
      get<{ data?: { items?: Record<string, unknown>[] } }>(
        `/api/v3/admin/profile/${encodeURIComponent(profileId)}/credits?limit=20&offset=0`,
        timeoutMs,
      ),
    ]);
    warnRejected("profile", profResp);
    warnRejected("credits", credResp);

    const row: Record<string, unknown> =
      profResp.status === "fulfilled" && profResp.value.ok ? (profResp.value.data?.data ?? {}) : {};
    const items =
      credResp.status === "fulfilled" && credResp.value.ok
        ? (credResp.value.data?.data?.items ?? [])
        : [];
    const latest = items
      .map((it) => ({ title: String(it.title ?? ""), date: String(it.releaseDate ?? "") }))
      .filter((c) => c.date)
      .sort((a, b) => b.date.localeCompare(a.date))[0];

    const cc = row.commonCredits;
    const primaryRole =
      Array.isArray(cc) && cc.length > 0
        ? String(cc[0])
        : String(row.role ?? row.primaryRole ?? "") || undefined;
    const creditsCount = Number(row.creditCount ?? row.creditsCount ?? 0);

    // Assemble ONLY the fields we want — this is what strips PII: email/phone/
    // payment on the profile row are never copied across.
    return {
      profileId,
      name: String(row.name ?? "") || undefined,
      profileUrl: `https://credits.muso.ai/profile/${profileId}`,
      ...(Object.keys(row).length > 0 ? { isClaimed: Boolean(row.isClaimed) } : {}),
      ...(primaryRole ? { primaryRole } : {}),
      ...(creditsCount > 0 ? { creditsCount } : {}),
      ...(latest?.title ? { latestCreditTitle: latest.title } : {}),
      ...(latest?.date ? { latestCreditDate: latest.date } : {}),
    };
  }

  async function lookupSnapshot(email: string, opts: { timeoutMs: number }): Promise<AccountSnapshot | null> {
    const { timeoutMs } = opts;
    try {
      // The two resolution legs are independent — a claiming failure must not
      // cost the customer their founder/plan facts, and vice versa.
      const [claimRes, teamRes] = await Promise.allSettled([
        resolveClaimedProfileId(email, timeoutMs),
        resolveTeamFacts(email, timeoutMs),
      ]);
      warnRejected("claiming", claimRes);
      warnRejected("team", teamRes);
      const profileId = claimRes.status === "fulfilled" ? claimRes.value : undefined;
      const teamFacts = teamRes.status === "fulfilled" ? teamRes.value : {};

      const workFields = profileId ? await fetchWorkFields(profileId, timeoutMs) : {};

      const snapshot: AccountSnapshot = { ...workFields, ...teamFacts };
      return Object.keys(snapshot).length > 0 ? snapshot : null;
    } catch (err) {
      deps.log?.warn?.(`[intercom] snapshot lookup error: ${err}`);
      return null;
    }
  }

  return { lookupSnapshot };
}
