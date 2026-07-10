import { describe, it, expect, vi, beforeEach } from "vitest";
import { createMusoAdminClient } from "../src/muso-admin-client.js";
import type { HttpClient, HttpResult } from "../src/http.js";

function makeLoginResponse(token: string): HttpResult<unknown> {
  return {
    ok: true,
    data: { data: { authentication: { accessToken: token } } },
  };
}

function makeHttp(overrides: Partial<HttpClient> = {}): HttpClient {
  return {
    get: vi.fn(async () => ({ ok: true, data: {} })) as HttpClient["get"],
    post: vi.fn(async () => makeLoginResponse("tok-default")) as HttpClient["post"],
    put: vi.fn(async () => ({ ok: true, data: {} })) as HttpClient["put"],
    ...overrides,
  };
}

describe("createMusoAdminClient", () => {
  let http: HttpClient;

  beforeEach(() => {
    http = makeHttp();
    vi.useFakeTimers();
  });

  it("calls login on first invocation", async () => {
    vi.mocked(http.post).mockResolvedValueOnce(makeLoginResponse("first-token"));
    vi.mocked(http.get).mockResolvedValueOnce({ ok: true, data: { items: [] } });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    await client.get("/api/v3/admin/profile/search?keyword=test");
    expect(http.post).toHaveBeenCalledTimes(1);
    expect(vi.mocked(http.post).mock.calls[0][0]).toBe("https://api.muso.ai/api/v3/admin/user/login");
  });

  it("caches token and reuses it on second call", async () => {
    vi.mocked(http.post).mockResolvedValue(makeLoginResponse("cached-token"));
    vi.mocked(http.get).mockResolvedValue({ ok: true, data: {} });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    await client.get("/api/v3/admin/profile/search?keyword=a");
    await client.get("/api/v3/admin/profile/search?keyword=b");

    // login called only once
    expect(http.post).toHaveBeenCalledTimes(1);
    // GET called with Authorization header carrying the cached token
    const calls = vi.mocked(http.get).mock.calls;
    expect(calls[0][1].headers?.Authorization).toBe("Bearer cached-token");
    expect(calls[1][1].headers?.Authorization).toBe("Bearer cached-token");
  });

  it("re-logs in after TOKEN_TTL_MS (22h) has elapsed", async () => {
    vi.mocked(http.post)
      .mockResolvedValueOnce(makeLoginResponse("old-token"))
      .mockResolvedValueOnce(makeLoginResponse("new-token"));
    vi.mocked(http.get).mockResolvedValue({ ok: true, data: {} });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    await client.get("/api/v3/admin/profile/search?keyword=x");
    // advance 23h past the 22h TTL
    vi.advanceTimersByTime(23 * 60 * 60 * 1000);
    await client.get("/api/v3/admin/profile/search?keyword=y");

    expect(http.post).toHaveBeenCalledTimes(2);
    const calls = vi.mocked(http.get).mock.calls;
    expect(calls[0][1].headers?.Authorization).toBe("Bearer old-token");
    expect(calls[1][1].headers?.Authorization).toBe("Bearer new-token");
  });

  it("returns path-not-allowlisted error for out-of-scope paths WITHOUT calling http.get", async () => {
    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const result = await client.get("/api/v3/admin/users");
    expect(result).toEqual({ ok: false, status: 0, error: "path not allowlisted" });
    expect(http.get).not.toHaveBeenCalled();
  });

  it("blocks paths that don't start with /api/v3/admin/", async () => {
    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const result = await client.get("/api/c/v5/search/autocomplete?q=test");
    expect(result).toEqual({ ok: false, status: 0, error: "path not allowlisted" });
    expect(http.get).not.toHaveBeenCalled();
  });

  it("blocks paths with '..' traversal segments", async () => {
    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const result = await client.get("/api/v3/admin/profile/../user");
    expect(result).toEqual({ ok: false, status: 0, error: "path not allowlisted" });
    expect(http.get).not.toHaveBeenCalled();
  });

  it("retries once on 401 with a refreshed token", async () => {
    vi.mocked(http.post)
      .mockResolvedValueOnce(makeLoginResponse("stale-token"))
      .mockResolvedValueOnce(makeLoginResponse("fresh-token"));

    vi.mocked(http.get)
      .mockResolvedValueOnce({ ok: false, status: 401, error: "Unauthorized" } as any)
      .mockResolvedValueOnce({ ok: true, data: { items: [] } });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const result = await client.get("/api/v3/admin/profile/search?keyword=x");
    expect(result.ok).toBe(true);
    expect(http.post).toHaveBeenCalledTimes(2);

    const getCalls = vi.mocked(http.get).mock.calls;
    expect(getCalls[0][1].headers?.Authorization).toBe("Bearer stale-token");
    expect(getCalls[1][1].headers?.Authorization).toBe("Bearer fresh-token");
  });

  it("does NOT retry a second 401 — returns error instead", async () => {
    vi.mocked(http.post)
      .mockResolvedValueOnce(makeLoginResponse("tok-1"))
      .mockResolvedValueOnce(makeLoginResponse("tok-2"));
    vi.mocked(http.get).mockResolvedValue({ ok: false, status: 401, error: "Unauthorized" } as any);

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const result = await client.get("/api/v3/admin/profile/search?keyword=x");
    expect(result.ok).toBe(false);
    expect((result as any).status).toBe(401);
    // Only 2 GET calls total (original + 1 retry), not infinite
    expect(http.get).toHaveBeenCalledTimes(2);
  });

  it("returns error when login HTTP call fails", async () => {
    vi.mocked(http.post).mockResolvedValue({ ok: false, status: 401, error: "Bad credentials" } as any);

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "wrong",
    });

    const result = await client.get("/api/v3/admin/profile/search?keyword=x");
    expect(result.ok).toBe(false);
    expect(result.status).toBe(0);
    expect(result.error).toMatch(/login failed/);
    expect(http.get).not.toHaveBeenCalled();
  });

  it("returns error when login response has no token", async () => {
    vi.mocked(http.post).mockResolvedValue({ ok: true, data: { data: {} } });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const result = await client.get("/api/v3/admin/profile/search?keyword=x");
    expect(result.ok).toBe(false);
    expect(result.error).toMatch(/login failed/);
    expect(http.get).not.toHaveBeenCalled();
  });

  it("never exposes the JWT in the public result", async () => {
    vi.mocked(http.post).mockResolvedValue(makeLoginResponse("super-secret-jwt"));
    vi.mocked(http.get).mockResolvedValue({ ok: true, data: { name: "Drake" } });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const result = await client.get<{ name: string }>("/api/v3/admin/profile/abc123def?");
    const json = JSON.stringify(result);
    expect(json).not.toContain("super-secret-jwt");
  });

  it("sends Service: caroline header", async () => {
    vi.mocked(http.post).mockResolvedValue(makeLoginResponse("tok"));
    vi.mocked(http.get).mockResolvedValue({ ok: true, data: {} });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    await client.get("/api/v3/admin/profile/search?keyword=x");
    const headers = vi.mocked(http.get).mock.calls[0][1].headers ?? {};
    expect(headers["Service"]).toBe("caroline");
  });

  it("allows bare profile path", async () => {
    vi.mocked(http.post).mockResolvedValue(makeLoginResponse("tok"));
    vi.mocked(http.get).mockResolvedValue({ ok: true, data: { id: "abc-123" } });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const result = await client.get("/api/v3/admin/profile/abc-123");
    expect(result.ok).toBe(true);
  });

  it("allows credits path", async () => {
    vi.mocked(http.post).mockResolvedValue(makeLoginResponse("tok"));
    vi.mocked(http.get).mockResolvedValue({ ok: true, data: { items: [] } });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const result = await client.get("/api/v3/admin/profile/abc-123/credits?limit=20&offset=0");
    expect(result.ok).toBe(true);
  });

  it("allows profile analytics-status read but blocks broader analytics profile sub-paths", async () => {
    vi.mocked(http.post).mockResolvedValue(makeLoginResponse("tok"));
    vi.mocked(http.get).mockResolvedValue({ ok: true, data: { data: { status: "fresh" } } });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    expect((await client.get("/api/v3/admin/profile/abc-123/analytics-status")).ok).toBe(true);
    expect(await client.get("/api/v3/admin/profile/abc-123/analytics-status/recheck")).toEqual({ ok: false, status: 0, error: "path not allowlisted" });
    expect(await client.get("/api/v3/admin/profile/abc-123/analytics")).toEqual({ ok: false, status: 0, error: "path not allowlisted" });
  });

  it("allows the credit-requests LIST path but blocks the per-item path (the approve/write surface)", async () => {
    vi.mocked(http.post).mockResolvedValue(makeLoginResponse("tok"));
    vi.mocked(http.get).mockResolvedValue({ ok: true, data: { data: { items: [] } } });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    const list = await client.get("/api/v3/admin/credit-requests?profilesIds=abc-123&status=user_verification_needed&limit=10");
    expect(list.ok).toBe(true);

    // Tripwire: the regex must stay scoped to the list endpoint — never the
    // /credit-requests/<id> item path that the gated approve PUT lives under.
    const item = await client.get("/api/v3/admin/credit-requests/123");
    expect(item).toEqual({ ok: false, status: 0, error: "path not allowlisted" });
    const bare = await client.get("/api/v3/admin/credit-requestsX");
    expect(bare).toEqual({ ok: false, status: 0, error: "path not allowlisted" });
  });

  it("allows a single-order read by id but blocks the write sub-paths and the bare list", async () => {
    vi.mocked(http.post).mockResolvedValue(makeLoginResponse("tok"));
    vi.mocked(http.get).mockResolvedValue({ ok: true, data: { data: { id: "abc" } } });

    const client = createMusoAdminClient({
      http,
      musoApiBase: "https://api.muso.ai",
      adminEmail: "admin@muso.ai",
      adminPassword: "s3cret",
    });

    // by UUID, by Prodigi numeric id, and by order number all match the segment.
    expect((await client.get("/api/v3/admin/orders/6a468d83-b71d-4720-bb12-79ae8dfa55f8")).ok).toBe(true);
    expect((await client.get("/api/v3/admin/orders/66812882101295104")).ok).toBe(true);
    expect((await client.get("/api/v3/admin/orders/k3n9Xa")).ok).toBe(true);

    // Tripwire: the write sub-paths and the payment-embedding list must NOT pass.
    for (const denied of [
      "/api/v3/admin/orders",
      "/api/v3/admin/orders/abc/tracking",
      "/api/v3/admin/orders/abc/retry-prodigi-order-create",
      "/api/v3/admin/orders/abc/complete-for-free",
    ]) {
      expect(await client.get(denied)).toEqual({ ok: false, status: 0, error: "path not allowlisted" });
    }
  });
});
