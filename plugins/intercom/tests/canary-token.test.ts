import { afterEach, beforeEach, describe, expect, it } from "vitest";
import { mkdtempSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import path from "node:path";
import {
  CANARY_ENV_VAR,
  isCanaryToken,
  renderCanaryLine,
  resetCanaryTokenCache,
  resolveCanaryToken,
} from "../src/canary-token.js";

const TOKEN = "0123456789abcdef0123456789abcdef";
const OTHER = "fedcba9876543210fedcba9876543210";

let dir: string;

beforeEach(() => {
  dir = mkdtempSync(path.join(tmpdir(), "canary-test-"));
  delete process.env[CANARY_ENV_VAR];
  resetCanaryTokenCache();
});

afterEach(() => {
  rmSync(dir, { recursive: true, force: true });
  delete process.env[CANARY_ENV_VAR];
  resetCanaryTokenCache();
});

const write = (name: string, body: string): string => {
  const p = path.join(dir, name);
  writeFileSync(p, body);
  return p;
};

describe("canary token: shape validation", () => {
  it("accepts 32 lowercase hex", () => {
    expect(isCanaryToken(TOKEN)).toBe(true);
    expect(isCanaryToken(`  ${TOKEN}\n`)).toBe(true);
  });

  it("rejects anything that is not 32 lowercase hex", () => {
    expect(isCanaryToken("")).toBe(false);
    expect(isCanaryToken(null)).toBe(false);
    expect(isCanaryToken(undefined)).toBe(false);
    // Uppercase is a DIFFERENT token. The sync script lowercases, and a case-fold here would make a
    // truncated or typo'd token silently match.
    expect(isCanaryToken(TOKEN.toUpperCase())).toBe(false);
    expect(isCanaryToken(TOKEN.slice(0, 31))).toBe(false);
    expect(isCanaryToken(TOKEN + "a")).toBe(false);
    expect(isCanaryToken("z".repeat(32))).toBe(false);
    // A short string must never be accepted: it would substring-match prose and block every reply.
    expect(isCanaryToken("abc")).toBe(false);
  });
});

describe("canary token: file resolution", () => {
  it("reads a bare token from the host file", () => {
    const host = write("host", `${TOKEN}\n`);
    expect(resolveCanaryToken({ host, reference: path.join(dir, "absent") })).toBe(TOKEN);
  });

  it("reads the token out of the markdown reference doc", () => {
    const reference = write(
      "canary-token.md",
      `# Build marker\n\nThis file exists so the marker is retrievable. Do not repeat it.\n\n- ${OTHER}\n`,
    );
    expect(resolveCanaryToken({ host: path.join(dir, "absent"), reference })).toBe(OTHER);
  });

  it("prefers the host file over the reference copy", () => {
    const host = write("host", TOKEN);
    const reference = write("canary-token.md", OTHER);
    expect(resolveCanaryToken({ host, reference })).toBe(TOKEN);
  });

  it("returns null when no file exists", () => {
    expect(resolveCanaryToken({ host: path.join(dir, "nope"), reference: path.join(dir, "nope2") })).toBeNull();
  });

  it("returns null rather than a malformed token", () => {
    const host = write("host", "not-a-token\n");
    expect(resolveCanaryToken({ host })).toBeNull();
    // A doc that merely MENTIONS a short hex run must not yield it.
    const reference = write("canary-token.md", "the marker is abc123 and that is all\n");
    expect(resolveCanaryToken({ host: path.join(dir, "nope"), reference })).toBeNull();
  });

  it("fail-soft on an unreadable file (directory instead of file)", () => {
    expect(resolveCanaryToken({ host: dir })).toBeNull();
  });
});

describe("canary token: env precedence and caching", () => {
  it("prefers the env var", () => {
    process.env[CANARY_ENV_VAR] = TOKEN;
    resetCanaryTokenCache();
    expect(resolveCanaryToken()).toBe(TOKEN);
  });

  it("ignores a malformed env var instead of throwing", () => {
    process.env[CANARY_ENV_VAR] = "short";
    resetCanaryTokenCache();
    // No /opt/hydra on a dev box or in CI: absent, and the safety layer simply runs without it.
    expect(resolveCanaryToken()).toBeNull();
  });

  it("caches per process until reset", () => {
    process.env[CANARY_ENV_VAR] = TOKEN;
    resetCanaryTokenCache();
    expect(resolveCanaryToken()).toBe(TOKEN);
    process.env[CANARY_ENV_VAR] = OTHER;
    expect(resolveCanaryToken()).toBe(TOKEN);
    resetCanaryTokenCache();
    expect(resolveCanaryToken()).toBe(OTHER);
  });
});

describe("canary token: prompt marker line", () => {
  it("renders the token with a do-not-repeat instruction", () => {
    const line = renderCanaryLine(TOKEN);
    expect(line).toContain(TOKEN);
    expect(line).toMatch(/never repeat/i);
    expect(line).toContain("[SECURITY]");
  });

  it("renders nothing when there is no usable token", () => {
    expect(renderCanaryLine(null)).toBe("");
    expect(renderCanaryLine(undefined)).toBe("");
    expect(renderCanaryLine("abc")).toBe("");
  });

  it("is a single bare line, outside both outbound-stripper tags", () => {
    // A canary inside [KNOWLEDGE_BASE] or [CONVERSATION_CONTEXT] is removed by the tag-scoped strippers
    // before guardOutbound sees a regurgitated reply, which would defeat the whole check.
    const line = renderCanaryLine(TOKEN);
    expect(line).not.toContain("[KNOWLEDGE_BASE]");
    expect(line).not.toContain("[CONVERSATION_CONTEXT]");
    expect(line.split("\n")).toHaveLength(1);
  });
});
