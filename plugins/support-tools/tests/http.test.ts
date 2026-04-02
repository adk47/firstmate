import { describe, it, expect, vi, beforeEach } from "vitest";
import { createHttpClient, type HttpResult } from "../src/http.js";

describe("createHttpClient", () => {
  beforeEach(() => {
    vi.restoreAllMocks();
  });

  it("returns ok result for successful GET with JSON response", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ name: "Drake" }),
    }));

    const client = createHttpClient();
    const result = await client.get("https://api.example.com/test", {
      headers: { "x-api-key": "test-key" },
    });

    expect(result).toEqual({ ok: true, data: { name: "Drake" } });
    expect(fetch).toHaveBeenCalledWith("https://api.example.com/test", {
      method: "GET",
      headers: { "x-api-key": "test-key" },
      signal: expect.any(AbortSignal),
    });
  });

  it("returns ok result for successful POST with JSON body", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: () => Promise.resolve({ id: "task_123" }),
    }));

    const client = createHttpClient();
    const result = await client.post("https://api.example.com/task", {
      headers: { Authorization: "pk_123" },
      body: { name: "Test Task" },
    });

    expect(result).toEqual({ ok: true, data: { id: "task_123" } });
    expect(fetch).toHaveBeenCalledWith("https://api.example.com/task", {
      method: "POST",
      headers: { Authorization: "pk_123", "Content-Type": "application/json" },
      body: JSON.stringify({ name: "Test Task" }),
      signal: expect.any(AbortSignal),
    });
  });

  it("returns error for 4xx/5xx responses", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: false,
      status: 403,
      json: () => Promise.resolve({ error: "Forbidden" }),
    }));

    const client = createHttpClient();
    const result = await client.get("https://api.example.com/test", {});

    expect(result).toEqual({ ok: false, error: "API error", status: 403 });
  });

  it("returns error for 429 rate limit", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: false,
      status: 429,
      json: () => Promise.resolve({}),
    }));

    const client = createHttpClient();
    const result = await client.get("https://api.example.com/test", {});

    expect(result).toEqual({ ok: false, error: "API rate limit exceeded", status: 429 });
  });

  it("returns error on fetch exception", async () => {
    vi.stubGlobal("fetch", vi.fn().mockRejectedValue(new Error("Network failure")));

    const client = createHttpClient();
    const result = await client.get("https://api.example.com/test", {});

    expect(result).toEqual({ ok: false, error: "Network failure" });
  });

  it("returns error on malformed JSON", async () => {
    vi.stubGlobal("fetch", vi.fn().mockResolvedValue({
      ok: true,
      status: 200,
      json: () => Promise.reject(new SyntaxError("Unexpected token")),
    }));

    const client = createHttpClient();
    const result = await client.get("https://api.example.com/test", {});

    expect(result).toEqual({ ok: false, error: "Invalid response from API" });
  });
});
