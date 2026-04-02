export type HttpResult<T = unknown> =
  | { ok: true; data: T }
  | { ok: false; error: string; status?: number };

export interface HttpClient {
  get<T = unknown>(url: string, opts: { headers?: Record<string, string> }): Promise<HttpResult<T>>;
  post<T = unknown>(url: string, opts: { headers?: Record<string, string>; body?: unknown }): Promise<HttpResult<T>>;
}

const DEFAULT_TIMEOUT_MS = 10_000;

async function request<T>(url: string, init: RequestInit): Promise<HttpResult<T>> {
  try {
    const controller = new AbortController();
    const timeout = setTimeout(() => controller.abort(), DEFAULT_TIMEOUT_MS);

    const res = await fetch(url, { ...init, signal: controller.signal });
    clearTimeout(timeout);

    if (!res.ok) {
      const error = res.status === 429 ? "API rate limit exceeded" : "API error";
      return { ok: false, error, status: res.status };
    }

    try {
      const data = (await res.json()) as T;
      return { ok: true, data };
    } catch {
      return { ok: false, error: "Invalid response from API" };
    }
  } catch (err) {
    if (err instanceof DOMException && err.name === "AbortError") {
      return { ok: false, error: "Request timed out" };
    }
    return { ok: false, error: err instanceof Error ? err.message : "Unknown error" };
  }
}

export function createHttpClient(): HttpClient {
  return {
    get<T>(url: string, opts: { headers?: Record<string, string> }) {
      return request<T>(url, { method: "GET", headers: opts.headers });
    },
    post<T>(url: string, opts: { headers?: Record<string, string>; body?: unknown }) {
      const headers = { ...opts.headers, "Content-Type": "application/json" };
      return request<T>(url, {
        method: "POST",
        headers,
        body: opts.body ? JSON.stringify(opts.body) : undefined,
      });
    },
  };
}
