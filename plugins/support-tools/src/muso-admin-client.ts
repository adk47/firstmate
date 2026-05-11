import type { HttpClient } from "./http.js";

interface AdminClientDeps {
  http: HttpClient;
  musoApiBase: string;
  adminEmail: string;
  adminPassword: string;
}

const ALLOWED_PATHS: RegExp[] = [
  /^\/api\/v3\/admin\/profile\/search(\?|$)/,
  /^\/api\/v3\/admin\/profile\/[0-9a-fA-F-]+(\?|$)/,
  /^\/api\/v3\/admin\/profile\/[0-9a-fA-F-]+\/credits(\?|$)/,
];

const TOKEN_TTL_MS = 22 * 60 * 60 * 1000; // refresh 1h before the 23h bash cache expires

export interface AdminClientResult<T = unknown> {
  ok: boolean;
  status: number;
  data?: T;
  error?: string;
}

export interface MusoAdminClient {
  get<T>(path: string): Promise<AdminClientResult<T>>;
}

export function createMusoAdminClient(deps: AdminClientDeps): MusoAdminClient {
  let cachedToken: string | null = null;
  let cachedAt = 0;

  async function login(): Promise<string> {
    const resp = await deps.http.post<{
      data?: {
        authentication?: { accessToken?: string };
        user?: { accessToken?: string };
      };
      token?: string;
    }>(`${deps.musoApiBase}/api/v3/admin/user/login`, {
      headers: { "Content-Type": "application/json", Accept: "application/json" },
      body: { email: deps.adminEmail, password: deps.adminPassword },
    });
    if (!resp.ok) {
      throw new Error(`admin login failed: HTTP ${(resp as { status?: number }).status ?? 0} ${(resp as { error?: string }).error ?? ""}`);
    }
    const tok =
      resp.data?.data?.authentication?.accessToken ??
      resp.data?.data?.user?.accessToken ??
      resp.data?.token ??
      "";
    if (!tok) throw new Error("admin login returned no token");
    return tok;
  }

  async function getToken(forceRefresh = false): Promise<string> {
    const now = Date.now();
    if (!forceRefresh && cachedToken && now - cachedAt < TOKEN_TTL_MS) {
      return cachedToken;
    }
    const fresh = await login();
    cachedToken = fresh;
    cachedAt = now;
    return fresh;
  }

  async function getInternal<T>(path: string, retried: boolean): Promise<AdminClientResult<T>> {
    if (!path.startsWith("/api/v3/admin/")) {
      return { ok: false, status: 0, error: "path not allowlisted" };
    }
    if (path.includes("..")) {
      return { ok: false, status: 0, error: "path not allowlisted" };
    }
    if (!ALLOWED_PATHS.some((re) => re.test(path))) {
      return { ok: false, status: 0, error: "path not allowlisted" };
    }

    let token: string;
    try {
      token = await getToken(false);
    } catch (e) {
      return { ok: false, status: 0, error: `login failed: ${(e as Error).message}` };
    }

    const resp = await deps.http.get<T>(`${deps.musoApiBase}${path}`, {
      headers: {
        Authorization: `Bearer ${token}`,
        Service: "caroline",
        Accept: "application/json",
      },
    });

    if (resp.ok) {
      return { ok: true, status: 200, data: resp.data };
    }

    const failResp = resp as { ok: false; status?: number; error?: string };
    const status = failResp.status ?? 0;
    if (status === 401 && !retried) {
      cachedToken = null;
      return getInternal<T>(path, true);
    }
    return { ok: false, status, error: failResp.error ?? "upstream error" };
  }

  return {
    get<T>(path: string) {
      return getInternal<T>(path, false);
    },
  };
}
