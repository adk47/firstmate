# Caroline analytics handoff — implementation plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace Caroline's "email support@muso.ai" no-op handoff with a real pushback-triggered ClickUp ticket; prove she read the customer's profile by exposing a bundled `profile_status` tool; enforce no-tool-leak and updated email allowlist deterministically in the outbound sanitizer.

**Architecture:** Five changes inside the existing edge gateway. (1) Enable the already-built `support-tools` plugin on the edge profile (currently not loaded). (2) Refactor `create_ticket` to return structured JSON; add `analytics-followup` actionType. (3) New `profile_status` tool bundling `profile_lookup` + `credits_search`. (4) Code-level outbound sanitizer for tool-leak terms; remove `jan@muso.ai` from email allowlist. (5) SOUL/KB updates aligning the model contract with the new tool/sanitizer reality. No new services, no agent-to-agent wiring, Caroline stays fully isolated.

**Tech Stack:** TypeScript, openclaw 4.x plugin SDK, `@sinclair/typebox`, vitest, ClickUp v2 API, Intercom v2.11 API, Muso `/api/c/v5` and `/api/c/v4` endpoints.

**Spec:** `docs/superpowers/specs/2026-05-11-caroline-analytics-handoff-design.md`

**Plan revision 2 (2026-05-11):** Inserted Task 1a before Task 1 after discovering during execution prep that the support-tools plugin has never loaded successfully on any profile — the openclaw runtime requires compiled `dist/` output for non-channel plugins, but the plugin's package.json has no `build` script and `deploy.sh` does not transpile. Empirical evidence: main gateway logs `"installed plugin package requires compiled runtime output for TypeScript entry src/index.ts: expected ./dist/index.js"` for support-tools at every restart. Plan revision adds the build step ahead of the edge config change so enabling the plugin on edge actually does something.

---

## File Structure

**Created:**
- `plugins/support-tools/src/tools/profile-status.ts` — new bundled lookup tool
- `plugins/support-tools/tests/profile-status.test.ts` — unit tests
- `plugins/intercom/src/sanitize-tool-leak.ts` — deterministic tool-leak sanitizer
- `plugins/intercom/tests/sanitize-tool-leak.test.ts` — unit tests

**Modified:**
- `openclaw-edge.json` — enable `support-tools` plugin (P0)
- `plugins/support-tools/src/tools/create-ticket.ts` — structured returns + `analytics-followup` actionType + SLA wording
- `plugins/support-tools/tests/create-ticket.test.ts` — assert new structured shape
- `plugins/support-tools/src/index.ts` — register `profile_status`
- `plugins/support-tools/tests/index.test.ts` — assert tool count = 5
- `plugins/intercom/src/sanitize-email.ts` — drop `jan@muso.ai` from allowlist
- `plugins/intercom/tests/sanitize-email.test.ts` — assert scrub
- `plugins/intercom/src/outbound.ts` — wire tool-leak sanitizer into `SanitizingIntercomClient`
- `plugins/intercom/tests/outbound.test.ts` — assert tool-leak sanitization runs on every outbound body
- `workspaces/support/SOUL.md` — tool count, `profile_status` entry, contact disclosure tightening, Tool Failure subsection
- `workspaces/support/TOOLS.md` — tool count + `profile_status` entry
- `workspaces/support/skills/refund-retention/SKILL.md` — tool count + analytics-followup precedence note
- `workspaces/support/skills/action-request/SKILL.md` — note `create_ticket` now returns structured JSON
- `workspaces/support/reference/common-issues.md` — analytics resolution path
- `workspaces/support/skills/output-sanitizer/SKILL.md` — cosmetic extension of prompt-level blocklist

---

## Task 1a: Add a build step so support-tools produces `dist/index.js`

**Files:**
- Modify: `plugins/support-tools/package.json` (add `build` script)
- Modify: `scripts/deploy.sh` (run `npm install` full, then `npm run build`)
- Modify: `.gitignore` (verify `dist/` is ignored inside plugin dirs; do not commit dist)

Without this, openclaw's runtime rejects the plugin at load time. The build step transforms `src/*.ts` → `dist/*.js` per the existing `tsconfig.json` (`outDir: ./dist`, `rootDir: ./src`).

- [ ] **Step 1: Add `build` script to package.json**

Edit `plugins/support-tools/package.json`. Insert the `build` entry into `scripts`:

```json
"scripts": {
  "build": "tsc",
  "test": "vitest run",
  "test:watch": "vitest"
},
```

- [ ] **Step 2: Verify local build works**

```bash
cd plugins/support-tools && npm install && npm run build && ls dist/
```
Expected: `dist/` contains `index.js`, plus a `.js` file for each `src/` source. If the build fails on a TS error, fix the error before continuing (this is the same compiler invocation deploy.sh will run).

- [ ] **Step 3: Confirm `dist/` stays out of git**

```bash
git status plugins/support-tools/dist 2>&1
```
Expected: nothing reported (already ignored). If `dist/` shows up, add `plugins/support-tools/dist/` to the repo's `.gitignore` and ensure it's not tracked.

- [ ] **Step 4: Update deploy.sh `install_plugin()` to build before rsync**

Read `scripts/deploy.sh` around line 259 where `npm install --production` is run. Two surgical edits:

a) Change the install command from `--production` to a full install, so devDependencies (typescript) are available for the build:

```bash
# was:  npm_out=$(cd "$plugin_dir" && npm install --production 2>&1) || npm_rc=$?
npm_out=$(cd "$plugin_dir" && npm install 2>&1) || npm_rc=$?
```

b) Immediately after the `npm install` block (and before `# Determine the target extension paths…`), add a build step. Skip if the plugin has no `build` script (so we don't break the intercom plugin which doesn't need it):

```bash
# Build the plugin if it declares a build script. Required for plugins that
# expose tools through TypeScript entries — openclaw 4.27+ rejects ./src/*.ts
# entries without compiled output unless the plugin is kind=channel. Channel
# plugins (intercom) load fine without dist; tool plugins (support-tools) do not.
if cd "$plugin_dir" && npm run | grep -qE "^  build$"; then
  build_out=$(cd "$plugin_dir" && npm run build 2>&1) || build_rc=$?
  if (( build_rc != 0 )); then
    log "    ✗ npm run build failed for $plugin_name (rc=$build_rc):"
    echo "$build_out" | sed 's/^/        /'
    return 1
  fi
fi
```

- [ ] **Step 5: Verify deploy.sh shellcheck still passes**

The pre-commit hook runs shellcheck on staged shell files. Verify locally:

```bash
shellcheck scripts/deploy.sh
```
Expected: same warnings as before, no new ones. (If shellcheck flags the `npm run | grep` line, switch to `[[ "$(jq -r '.scripts.build // empty' "$plugin_dir/package.json")" ]]`.)

- [ ] **Step 6: Commit**

```bash
git add plugins/support-tools/package.json scripts/deploy.sh
git commit -m "fix(deploy): build support-tools plugin to dist/ before rsync — openclaw runtime requires compiled output for tool plugins"
```

---

## Task 1: P0 — Enable `support-tools` plugin on edge gateway

**Files:**
- Modify: `openclaw-edge.json` (plugins.allow + plugins.load.paths)

The edge gateway currently has `plugins.allow: ["slack", "intercom"]` and `plugins.load.paths: ["/root/.openclaw-edge/extensions/intercom"]`. Caroline runs with zero custom tools. Adding `support-tools` to both lists is the gating change for everything else in this plan.

- [ ] **Step 1: Read current edge config**

```bash
jq '.plugins | {allow: .allow, load_paths: .load.paths}' openclaw-edge.json
```

Expected output:
```json
{
  "allow": ["slack", "intercom"],
  "load_paths": ["/root/.openclaw-edge/extensions/intercom"]
}
```

- [ ] **Step 2: Add `support-tools` to `plugins.allow`**

Edit `openclaw-edge.json`. Locate the `plugins.allow` array and add `"support-tools"`:

```json
"plugins": {
  "allow": [
    "slack",
    "intercom",
    "support-tools"
  ],
```

- [ ] **Step 3: Add load path for support-tools**

In the same file, locate `plugins.load.paths` and add the directory:

```json
"load": {
  "paths": [
    "/root/.openclaw-edge/extensions/intercom",
    "/root/.openclaw-edge/extensions/support-tools"
  ]
}
```

- [ ] **Step 4: Add an `installs` entry for support-tools**

The `intercom` plugin already has an `installs.intercom` block describing source/spec/installPath. Add a sibling entry for `support-tools` immediately after it inside `plugins.installs`:

```json
"installs": {
  "intercom": { … existing … },
  "support-tools": {
    "source": "path",
    "spec": "/root/.openclaw-edge/extensions/support-tools",
    "installPath": "/root/.openclaw-edge/extensions/support-tools",
    "resolvedName": "@muso/support-tools",
    "resolvedVersion": "0.1.0"
  }
}
```

- [ ] **Step 5: Add a `plugins.entries["support-tools"]` config block**

This is how openclaw 4.27 passes plugin config (musoApiKey, clickupApiKey, etc.). Add to `plugins.entries` immediately after the existing `slack`/`intercom` entries:

```json
"entries": {
  "slack": { "enabled": true },
  "intercom": { "enabled": true },
  "support-tools": {
    "enabled": true,
    "config": {
      "musoApiBase": "https://api.muso.ai",
      "musoApiKey": { "source": "env", "id": "MUSO_CUSTOMER_API_KEY" },
      "clickupApiKey": { "source": "env", "id": "CLICKUP_API_KEY" },
      "clickupListId": "901000600160",
      "clickupProfileIdFieldId": { "source": "env", "id": "CLICKUP_PROFILE_ID_FIELD_ID" },
      "clickupUserEmailFieldId": { "source": "env", "id": "CLICKUP_USER_EMAIL_FIELD_ID" }
    }
  }
}
```

**Verify the secret-ref shape against the existing `slack`/`intercom` `entries` blocks in `openclaw-main.json` — if main uses a different secret-ref schema, mirror that one. The example above is the SDK default; pre-existing profiles are the source of truth.**

- [ ] **Step 6: Validate JSON**

```bash
jq '.' openclaw-edge.json > /dev/null && echo "valid"
```
Expected: `valid`

- [ ] **Step 7: Verify deploy.sh copies support-tools to edge**

```bash
grep -n "support-tools\|extensions" deploy.sh | head -20
```
Confirm `deploy.sh` rsyncs `plugins/support-tools/` into `/root/.openclaw-edge/extensions/support-tools/`. If it does NOT — and currently the plugin dir on hydra exists, so it likely does — add a matching rsync entry alongside the intercom one. **If you must add a new rsync invocation, update the shared excludes array used by pre-commit check `[2/7]` (see `.githooks/pre-commit`).**

- [ ] **Step 8: Commit**

```bash
git add openclaw-edge.json
git commit -m "feat(edge): enable support-tools plugin (P0 — was unregistered, blocking all 4 support agent tools)"
```

---

## Task 2: Refactor `create_ticket` returns to structured JSON

**Files:**
- Modify: `plugins/support-tools/src/tools/create-ticket.ts`
- Modify: `plugins/support-tools/tests/create-ticket.test.ts`

Today every `create_ticket` return is customer-facing English: `"Support request #123 created…"`, `"Unable to create a ticket right now. Please email support@muso.ai directly."`, `"You've already submitted requests this session…"`. These violate the new SOUL contract (no "ticket" word, no email handoff). Refactor to structured JSON; Caroline composes the customer reply.

- [ ] **Step 1: Write failing tests for the new return shape**

Replace the existing return-value assertions in `plugins/support-tools/tests/create-ticket.test.ts` with the structured shape. Add these test cases to the existing `describe("createCreateTicketTool")` block (or create one if absent):

```typescript
import { describe, it, expect, vi } from "vitest";
import { createCreateTicketTool, TIER_SLAS } from "../src/tools/create-ticket.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { HttpClient } from "../src/http.js";

function makeHttp(overrides: Partial<HttpClient> = {}): HttpClient {
  return {
    get: vi.fn(async () => ({ ok: true, data: {} as any })),
    post: vi.fn(async () => ({ ok: true, data: { id: "abc123" } as any })),
    put: vi.fn(async () => ({ ok: true, data: {} as any })),
    ...overrides,
  } as unknown as HttpClient;
}

function makeDeps(overrides: Partial<Parameters<typeof createCreateTicketTool>[0]> = {}) {
  return {
    http: makeHttp(),
    rateLimiter: new RateLimiter(),
    clickupApiKey: "k",
    clickupListId: "list",
    clickupProfileIdFieldId: "pf",
    clickupUserEmailFieldId: "ef",
    sessionId: "sess-1",
    ...overrides,
  };
}

describe("createCreateTicketTool — structured returns", () => {
  it("returns structured success on ticket creation", async () => {
    const tool = createCreateTicketTool(makeDeps());
    const result = await tool.execute("call-1", {
      actionType: "analytics-followup",
      customerEmail: "u@example.com",
      summary: "stuck streams",
      conversationSummary: "customer reports stale dashboard",
    } as any);
    const parsed = JSON.parse(result.content[0].text as string);
    expect(parsed).toEqual({
      submitted: true,
      ticket_id: "abc123",
      sla: "2 business days",
      action_type: "analytics-followup",
      tier: 1,
    });
  });

  it("returns structured queue_busy on ClickUp 5xx", async () => {
    const http = makeHttp({ post: vi.fn(async () => ({ ok: false, status: 503, error: "upstream" })) });
    const tool = createCreateTicketTool(makeDeps({ http }));
    const result = await tool.execute("call-1", {
      actionType: "analytics-followup",
      customerEmail: "u@example.com",
      summary: "x",
      conversationSummary: "y",
    } as any);
    const parsed = JSON.parse(result.content[0].text as string);
    expect(parsed).toEqual({ submitted: false, reason: "queue_busy" });
  });

  it("returns structured rate_limited when session cap exceeded", async () => {
    const deps = makeDeps();
    const tool = createCreateTicketTool(deps);
    // first two succeed under default 60min/2 cap
    await tool.execute("c1", { actionType: "support-general", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    await tool.execute("c2", { actionType: "support-general", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    const result = await tool.execute("c3", { actionType: "support-general", customerEmail: "u@example.com", summary: "s", conversationSummary: "c" } as any);
    const parsed = JSON.parse(result.content[0].text as string);
    expect(parsed).toEqual({ submitted: false, reason: "rate_limited" });
  });

  it("never returns customer-facing English in any path", async () => {
    const deps = makeDeps({ http: makeHttp({ post: vi.fn(async () => ({ ok: false, status: 500, error: "x" })) }) });
    const tool = createCreateTicketTool(deps);
    const result = await tool.execute("call-1", {
      actionType: "analytics-followup",
      customerEmail: "u@example.com",
      summary: "s",
      conversationSummary: "c",
    } as any);
    const text = result.content[0].text as string;
    // Must be valid JSON. Must not contain forbidden words.
    expect(() => JSON.parse(text)).not.toThrow();
    expect(text).not.toMatch(/ticket|support@muso\.ai|already submitted|Unable/i);
  });

  it("includes analytics-followup in tag list passed to ClickUp", async () => {
    const post = vi.fn(async () => ({ ok: true, data: { id: "abc" } as any }));
    const tool = createCreateTicketTool(makeDeps({ http: makeHttp({ post }) }));
    await tool.execute("c", {
      actionType: "analytics-followup",
      customerEmail: "u@example.com",
      summary: "s",
      conversationSummary: "c",
    } as any);
    const calledBody = (post.mock.calls[0]?.[1] as any)?.body;
    expect(calledBody?.tags).toContain("analytics-followup");
    expect(calledBody?.tags).toContain("hydra-action-request");
    expect(calledBody?.tags).toContain("tier-1");
  });
});

describe("TIER_SLAS", () => {
  it("tier 1 is '2 business days'", () => {
    expect(TIER_SLAS[1]).toBe("2 business days");
  });
});
```

Also update existing tests in this file: the previous assertions that expected text like `"Support request #abc123 created"` must be replaced with parsed-JSON assertions. Read the full file and update every `expect(result.content[0].text).toContain("…english…")` to instead `JSON.parse` and check the structured fields.

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd plugins/support-tools && pnpm test create-ticket
```
Expected: failures referencing the new structured-shape assertions and `TIER_SLAS[1]`.

- [ ] **Step 3: Implement the refactor**

Edit `plugins/support-tools/src/tools/create-ticket.ts`:

a) Add `analytics-followup` to `TIER_MAP`:
```typescript
const TIER_MAP: Record<string, number> = {
  "credit-claim": 1, "credit-correction": 1, "profile-claim": 1, "support-general": 1, "analytics-followup": 1,
  "profile-merge": 2, "bulk-credit-change": 2, "profile-update": 2,
  "subscription-refund": 3, "data-deletion": 3, "dispute": 3, "data-export": 3,
};
```

b) Update `TIER_SLAS`:
```typescript
export const TIER_SLAS: Record<number, string> = {
  1: "2 business days",
  2: "5 business days",
  3: "5-10 business days",
};
```

c) Replace every `return textResult("english…")` in `execute` with structured JSON. Concretely the three current sites become:

```typescript
// rate-limit path
if (!rateLimiter.check(sessionId, "create_ticket", 60, 2).allowed) {
  return textResult(JSON.stringify({ submitted: false, reason: "rate_limited" }));
}

// ClickUp failure path
if (!result.ok) {
  return textResult(JSON.stringify({ submitted: false, reason: "queue_busy" }));
}

// success path
return textResult(JSON.stringify({
  submitted: true,
  ticket_id: result.data.id,
  sla,
  action_type: params.actionType,
  tier,
}));
```

d) In the `tags` array passed to ClickUp inside the POST body, include the actionType as a tag for tier-1 analytics:

```typescript
const tags = ["hydra-action-request", `tier-${tier}`];
if (params.actionType === "analytics-followup") tags.push("analytics-followup");
```

e) Update the tool's `description` to mention the new actionType in the comma-separated list.

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd plugins/support-tools && pnpm test create-ticket
```
Expected: all green.

- [ ] **Step 5: Run the full plugin test suite**

```bash
cd plugins/support-tools && pnpm test
```
Expected: all green (no regressions in profile-lookup, credits-search, etc.).

- [ ] **Step 6: Commit**

```bash
git add plugins/support-tools/src/tools/create-ticket.ts plugins/support-tools/tests/create-ticket.test.ts
git commit -m "refactor(support-tools): create_ticket returns structured JSON + adds analytics-followup actionType"
```

---

## Task 3: Update `action-request` and `refund-retention` skills for structured shape

**Files:**
- Modify: `workspaces/support/skills/action-request/SKILL.md`
- Modify: `workspaces/support/skills/refund-retention/SKILL.md`

These two skills currently instruct Caroline based on the assumption that `create_ticket` returns a human-readable string. Update them to read the structured shape.

- [ ] **Step 1: Update `action-request/SKILL.md`**

Find the section under "How It Works" step 4 ("CS agent tells the customer: 'I've submitted your request. Our team will review it within [SLA].'"). Replace with:

```markdown
4. CS agent reads `create_ticket`'s structured response:
   - `{ submitted: true, ticket_id, sla, action_type, tier }` — tell the customer: *"I've flagged your request for our team. You'll hear back within `<sla>`."*
   - `{ submitted: false, reason: "rate_limited" }` — acknowledge and stop: *"Looks like a request is already on the way to our team for you. You'll hear back soon."*
   - `{ submitted: false, reason: "queue_busy" }` — ask the customer to retry their message in a moment: *"Could you send that to me one more time? I want to make sure our team gets the full picture."*
   - Never use the words "ticket", "ClickUp", "task", or `support@muso.ai` in the customer-facing reply.
```

- [ ] **Step 2: Update `refund-retention/SKILL.md`**

In the same file find any references to a textual return shape from `create_ticket` and reword them to the structured shape, matching the language in Step 1. The retention flow's final hand-off (when the customer chooses to proceed with the refund) calls `create_ticket` with `actionType: "subscription-refund"` — update the success messaging to read `sla` from the structured response.

Also update the tool-count statement on line 22 from `"existing 4 tools (profile_lookup, credits_search, subscription_status, create_ticket)"` to `"existing 5 tools (profile_lookup, credits_search, subscription_status, create_ticket, profile_status)"`.

- [ ] **Step 3: Commit**

```bash
git add workspaces/support/skills/action-request/SKILL.md workspaces/support/skills/refund-retention/SKILL.md
git commit -m "docs(support): action-request + refund-retention skills read structured create_ticket response"
```

---

## Task 4: New `profile_status` tool

**Files:**
- Create: `plugins/support-tools/src/tools/profile-status.ts`
- Create: `plugins/support-tools/tests/profile-status.test.ts`

Bundled lookup. Returns `{ found, profile, latest_credits, latest_credit_date }` or a structured failure. Reuses the same Muso endpoints `profile_lookup`/`credits_search` already hit; no new infra.

- [ ] **Step 1: Write failing tests**

Create `plugins/support-tools/tests/profile-status.test.ts`:

```typescript
import { describe, it, expect, vi } from "vitest";
import { createProfileStatusTool } from "../src/tools/profile-status.js";
import { RateLimiter } from "../src/rate-limiter.js";
import type { HttpClient } from "../src/http.js";

function makeHttp(overrides: Partial<HttpClient> = {}): HttpClient {
  return {
    get: vi.fn(async () => ({ ok: true, data: { results: [] } as any })),
    post: vi.fn(async () => ({ ok: true, data: { results: [] } as any })),
    put: vi.fn(async () => ({ ok: true, data: {} as any })),
    ...overrides,
  } as unknown as HttpClient;
}

function makeDeps(overrides: Partial<Parameters<typeof createProfileStatusTool>[0]> = {}) {
  return {
    http: makeHttp(),
    rateLimiter: new RateLimiter(),
    musoApiBase: "https://api.muso.ai",
    musoApiKey: "k",
    sessionId: "sess-1",
    ...overrides,
  };
}

async function call(tool: ReturnType<typeof createProfileStatusTool>, params: Record<string, unknown>) {
  const result = await tool.execute("call-1", params as any);
  return JSON.parse(result.content[0].text as string);
}

describe("profile_status", () => {
  it("returns found:true with bundled fields on happy path", async () => {
    const http = makeHttp({
      get: vi.fn(async (url: string) => {
        if (url.includes("/search/autocomplete")) {
          return { ok: true, data: { results: [
            { id: "p1", name: "Aasis Beats", type: "profile", verified: true, creditCount: 142, role: "Producer" },
          ] } } as any;
        }
        if (url.includes("/profile/p1/credits")) {
          return { ok: true, data: { items: [
            { credits: [{ child: "Producer" }], track: { title: "Track A" }, album: { title: "Album A" }, releaseDate: "2026-05-08", artists: [{ name: "X" }] },
            { credits: [{ child: "Producer" }], track: { title: "Track B" }, album: { title: "Album B" }, releaseDate: "2026-04-30", artists: [{ name: "Y" }] },
            { credits: [{ child: "Producer" }], track: { title: "Track C" }, album: { title: "Album C" }, releaseDate: "2026-05-02", artists: [{ name: "Z" }] },
          ], totalCount: 3, hasMoreToLoad: false } } as any;
        }
        return { ok: true, data: {} } as any;
      }),
    });
    const tool = createProfileStatusTool(makeDeps({ http }));
    const out = await call(tool, { name: "Aasis Beats" });
    expect(out.found).toBe(true);
    expect(out.profile).toEqual({
      id: "p1",
      name: "Aasis Beats",
      verified: true,
      primary_role: "Producer",
      credits_count: 142,
    });
    // sorted by releaseDate desc → A (May 8), C (May 2), B (Apr 30)
    expect(out.latest_credits.map((c: any) => c.track)).toEqual(["Track A", "Track C", "Track B"]);
    expect(out.latest_credit_date).toBe("2026-05-08");
  });

  it("returns no_match when autocomplete and search both empty", async () => {
    const http = makeHttp({
      get: vi.fn(async () => ({ ok: true, data: { results: [] } } as any)),
      post: vi.fn(async () => ({ ok: true, data: { results: [] } } as any)),
    });
    const tool = createProfileStatusTool(makeDeps({ http }));
    const out = await call(tool, { name: "nobody" });
    expect(out).toEqual({ found: false, reason: "no_match" });
  });

  it("returns multiple_matches with top-3 names", async () => {
    const http = makeHttp({
      get: vi.fn(async () => ({ ok: true, data: { results: [
        { id: "a", name: "John Smith" }, { id: "b", name: "John Smithson" },
        { id: "c", name: "John A. Smith" }, { id: "d", name: "John Smyth" },
      ] } } as any)),
    });
    const tool = createProfileStatusTool(makeDeps({ http }));
    const out = await call(tool, { name: "John Smith" });
    expect(out).toEqual({ found: false, reason: "multiple_matches", matches: ["John Smith", "John Smithson", "John A. Smith"] });
  });

  it("returns lookup_unavailable on upstream 5xx", async () => {
    const http = makeHttp({
      get: vi.fn(async () => ({ ok: false, status: 500, error: "x" } as any)),
      post: vi.fn(async () => ({ ok: false, status: 500, error: "x" } as any)),
    });
    const tool = createProfileStatusTool(makeDeps({ http }));
    const out = await call(tool, { name: "Aasis" });
    expect(out).toEqual({ found: false, reason: "lookup_unavailable" });
  });

  it("returns missing_input when no identifier provided", async () => {
    const tool = createProfileStatusTool(makeDeps());
    const out = await call(tool, {});
    expect(out).toEqual({ found: false, reason: "missing_input" });
  });

  it("returns rate_limited when session cap exceeded", async () => {
    const deps = makeDeps();
    const tool = createProfileStatusTool(deps);
    for (let i = 0; i < 10; i++) await call(tool, { name: "X" });
    const out = await call(tool, { name: "X" });
    expect(out).toEqual({ found: false, reason: "rate_limited" });
  });

  it("never throws — always returns structured JSON", async () => {
    const http = makeHttp({
      get: vi.fn(async () => { throw new Error("network exploded"); }),
    });
    const tool = createProfileStatusTool(makeDeps({ http }));
    const out = await call(tool, { name: "Aasis" });
    expect(out.found).toBe(false);
    expect(out.reason).toBe("lookup_unavailable");
  });

  it("accepts profile_url and extracts UUID", async () => {
    const http = makeHttp({
      get: vi.fn(async (url: string) => {
        if (url.includes("/profile/90b6866c-7026-458e-a1af-48b1c1ac1c37/credits")) {
          return { ok: true, data: { items: [], totalCount: 0, hasMoreToLoad: false } } as any;
        }
        if (url.includes("/profile/90b6866c-7026-458e-a1af-48b1c1ac1c37")) {
          return { ok: true, data: { id: "90b6866c-7026-458e-a1af-48b1c1ac1c37", name: "Aasis", verified: false, role: "Producer", creditCount: 0 } } as any;
        }
        return { ok: true, data: { results: [] } } as any;
      }),
    });
    const tool = createProfileStatusTool(makeDeps({ http }));
    const out = await call(tool, { profile_url: "https://credits.muso.ai/profile/90b6866c-7026-458e-a1af-48b1c1ac1c37" });
    expect(out.found).toBe(true);
    expect(out.profile.id).toBe("90b6866c-7026-458e-a1af-48b1c1ac1c37");
  });

  it("PII filter: never echoes email or phone in output", async () => {
    const http = makeHttp({
      get: vi.fn(async (url: string) => {
        if (url.includes("/search/autocomplete")) {
          return { ok: true, data: { results: [
            { id: "p1", name: "User", verified: false, creditCount: 0, email: "u@example.com", phone: "+1234" },
          ] } } as any;
        }
        return { ok: true, data: { items: [] } } as any;
      }),
    });
    const tool = createProfileStatusTool(makeDeps({ http }));
    const out = await call(tool, { name: "User" });
    const json = JSON.stringify(out);
    expect(json).not.toMatch(/u@example\.com|\+1234/);
  });

  it("input precedence: profile_id > profile_url > email > name", async () => {
    const get = vi.fn(async (url: string) => {
      if (url.includes("/profile/EXPECTED")) {
        return { ok: true, data: { id: "EXPECTED", name: "Z", verified: false, role: "X", creditCount: 0 } } as any;
      }
      if (url.includes("/profile/EXPECTED/credits")) {
        return { ok: true, data: { items: [] } } as any;
      }
      return { ok: false, status: 404, error: "x" } as any;
    });
    const tool = createProfileStatusTool(makeDeps({ http: makeHttp({ get }) }));
    const out = await call(tool, {
      profile_id: "EXPECTED",
      profile_url: "https://credits.muso.ai/profile/SHOULD_NOT_USE",
      email: "x@x.com",
      name: "Z",
    });
    expect(out.found).toBe(true);
    expect(out.profile.id).toBe("EXPECTED");
  });
});
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd plugins/support-tools && pnpm test profile-status
```
Expected: all fail with `Cannot find module './tools/profile-status.js'`.

- [ ] **Step 3: Implement the tool**

Create `plugins/support-tools/src/tools/profile-status.ts`:

```typescript
import { Type, type Static } from "@sinclair/typebox";
import { textResult, type AgentTool, type AgentToolResult } from "../types.js";
import type { HttpClient } from "../http.js";
import type { RateLimiter } from "../rate-limiter.js";
import { extractProfileIdFromUrl } from "./profile-lookup.js";

const Parameters = Type.Object({
  profile_id: Type.Optional(Type.String({ description: "Bare Muso profile UUID" })),
  profile_url: Type.Optional(Type.String({ description: "Full https://credits.muso.ai/profile/<uuid> URL" })),
  email: Type.Optional(Type.String({ description: "Customer account email — used for lookup, never echoed back" })),
  name: Type.Optional(Type.String({ description: "Profile display name to resolve via autocomplete/search" })),
});

type Params = Static<typeof Parameters>;

interface ToolDeps {
  http: HttpClient;
  rateLimiter: RateLimiter;
  musoApiBase: string;
  musoApiKey: string;
  sessionId: string;
}

const PII_KEYS = new Set(["email", "phone", "phoneNumber", "address", "paymentMethod", "stripeId"]);

function stripPii(obj: Record<string, unknown>): Record<string, unknown> {
  const out: Record<string, unknown> = {};
  for (const [k, v] of Object.entries(obj)) {
    if (PII_KEYS.has(k)) continue;
    out[k] = v;
  }
  return out;
}

function structuredFailure(reason: string, extra: Record<string, unknown> = {}): AgentToolResult<unknown> {
  return textResult(JSON.stringify({ found: false, reason, ...extra }));
}

export function createProfileStatusTool(deps: ToolDeps): AgentTool<typeof Parameters, unknown> {
  const { http, rateLimiter, musoApiBase, musoApiKey, sessionId } = deps;
  const headers = { "x-api-key": musoApiKey };

  return {
    name: "profile_status",
    label: "Profile Status",
    description:
      "Bundled read-only view of a customer's profile — name, role, verified flag, credits count, and the latest 3 credits (sorted by release date descending). Returns structured JSON. Use this FIRST whenever a customer mentions analytics, streams, data freshness, or whether their account 'is working'.",
    parameters: Parameters,
    async execute(_toolCallId: string, params: Params): Promise<AgentToolResult<unknown>> {
      try {
        if (!rateLimiter.check(sessionId, "profile_status", 1, 10).allowed) {
          return structuredFailure("rate_limited");
        }

        // Input precedence: profile_id > profile_url > email > name
        let profileId: string | null = null;
        if (params.profile_id) profileId = params.profile_id;
        else if (params.profile_url) profileId = extractProfileIdFromUrl(params.profile_url);

        // No direct identifier — resolve via search using email or name.
        if (!profileId && !params.email && !params.name) {
          return structuredFailure("missing_input");
        }

        // Resolve via search when we don't have a direct ID.
        if (!profileId) {
          const query = params.email ?? params.name ?? "";
          const acURL = `${musoApiBase}/api/c/v5/search/autocomplete?q=${encodeURIComponent(query)}&types=profiles&limit=5`;
          const acResp = await http.get<{ results: Record<string, unknown>[] }>(acURL, { headers });
          let results: Record<string, unknown>[] = [];
          if (acResp.ok) results = acResp.data.results ?? [];

          if (results.length === 0) {
            const fullResp = await http.post<{ results: Record<string, unknown>[] }>(
              `${musoApiBase}/api/c/v5/search`,
              { headers, body: { keyword: query, type: ["profile"], limit: 10 } },
            );
            if (!fullResp.ok && !acResp.ok) return structuredFailure("lookup_unavailable");
            if (fullResp.ok) results = fullResp.data.results ?? [];
          }

          if (results.length === 0) return structuredFailure("no_match");
          if (results.length > 1) {
            return structuredFailure("multiple_matches", {
              matches: results.slice(0, 3).map((r) => String(r.name ?? "")),
            });
          }
          profileId = String(results[0].id ?? "");
          // continue with the single match's data
          const r = stripPii(results[0]);
          return await fetchCreditsAndAssemble(http, musoApiBase, headers, profileId, r);
        }

        // Direct profileId path — fetch profile + credits.
        const profResp = await http.get<Record<string, unknown>>(
          `${musoApiBase}/api/c/v5/search/autocomplete?q=${encodeURIComponent(profileId)}&types=profiles&limit=1`,
          { headers },
        );
        let profileRow: Record<string, unknown> | null = null;
        if (profResp.ok && Array.isArray((profResp.data as any).results) && (profResp.data as any).results.length > 0) {
          profileRow = (profResp.data as any).results[0];
        }
        // If autocomplete doesn't surface the UUID, fall back to a direct profile fetch.
        if (!profileRow) {
          const direct = await http.get<Record<string, unknown>>(
            `${musoApiBase}/api/c/v4/profile/${encodeURIComponent(profileId)}`,
            { headers },
          );
          if (!direct.ok) return structuredFailure("lookup_unavailable");
          profileRow = direct.data;
        }
        return await fetchCreditsAndAssemble(http, musoApiBase, headers, profileId, stripPii(profileRow));
      } catch (_err) {
        return structuredFailure("lookup_unavailable");
      }
    },
  };
}

async function fetchCreditsAndAssemble(
  http: HttpClient,
  musoApiBase: string,
  headers: Record<string, string>,
  profileId: string,
  profileRow: Record<string, unknown>,
): Promise<AgentToolResult<unknown>> {
  const credResp = await http.get<{ items: Record<string, unknown>[] }>(
    `${musoApiBase}/api/c/v4/profile/${encodeURIComponent(profileId)}/credits?limit=20&offset=0`,
    { headers },
  );
  if (!credResp.ok) return textResult(JSON.stringify({ found: false, reason: "lookup_unavailable" }));

  const items = credResp.data.items ?? [];
  const latest = items
    .map((it) => {
      const credits = (it.credits as unknown[]) ?? [];
      const role = typeof credits[0] === "string"
        ? String(credits[0])
        : String(((credits[0] as Record<string, unknown>) ?? {}).child ?? "");
      const track = (it.track as Record<string, unknown>) ?? {};
      const album = (it.album as Record<string, unknown>) ?? {};
      return {
        track: String(track.title ?? ""),
        release: String(album.title ?? ""),
        role,
        date: String(it.releaseDate ?? ""),
      };
    })
    .filter((c) => c.date)
    .sort((a, b) => b.date.localeCompare(a.date))
    .slice(0, 3);

  const output = {
    found: true,
    profile: {
      id: profileId,
      name: String(profileRow.name ?? ""),
      verified: Boolean(profileRow.verified),
      primary_role: String(profileRow.role ?? profileRow.primaryRole ?? ""),
      credits_count: Number(profileRow.creditCount ?? profileRow.creditsCount ?? 0),
    },
    latest_credits: latest,
    latest_credit_date: latest[0]?.date ?? "",
  };
  return textResult(JSON.stringify(output));
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd plugins/support-tools && pnpm test profile-status
```
Expected: all green.

- [ ] **Step 5: Commit**

```bash
git add plugins/support-tools/src/tools/profile-status.ts plugins/support-tools/tests/profile-status.test.ts
git commit -m "feat(support-tools): add profile_status bundled read-only tool with structured failure shape"
```

---

## Task 5: Register `profile_status` in plugin index

**Files:**
- Modify: `plugins/support-tools/src/index.ts`
- Modify: `plugins/support-tools/tests/index.test.ts`

- [ ] **Step 1: Write failing test for 5-tool registration**

In `plugins/support-tools/tests/index.test.ts`, locate any existing tool-count assertion and update it. If no such assertion exists, add this test:

```typescript
import { describe, it, expect, vi } from "vitest";
import pluginEntry from "../src/index.js";

describe("support-tools plugin entry", () => {
  it("registers exactly 5 tools", () => {
    const registered: string[] = [];
    const api = {
      pluginConfig: {
        musoApiBase: "https://api.muso.ai",
        musoApiKey: "k", clickupApiKey: "k", clickupListId: "list",
        clickupProfileIdFieldId: "pf", clickupUserEmailFieldId: "ef",
      },
      registerTool: (_factory: any, opts: { name: string }) => { registered.push(opts.name); },
    };
    (pluginEntry as any).register(api);
    expect(registered.sort()).toEqual([
      "create_ticket",
      "credits_search",
      "profile_lookup",
      "profile_status",
      "subscription_status",
    ]);
  });
});
```

- [ ] **Step 2: Run test to confirm it fails**

```bash
cd plugins/support-tools && pnpm test index
```
Expected: only 4 names registered, missing `profile_status`.

- [ ] **Step 3: Register the new tool in `src/index.ts`**

Add the import near the other tool imports:
```typescript
import { createProfileStatusTool } from "./tools/profile-status.js";
```

Inside `register(api)`, after the `creditsSearchFactory` registration, add:
```typescript
const profileStatusFactory = (ctx: any) => {
  return createProfileStatusTool({ http, rateLimiter, musoApiBase, musoApiKey, sessionId: ctx.sessionId ?? "unknown" });
};
api.registerTool(profileStatusFactory, { name: "profile_status" });
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd plugins/support-tools && pnpm test
```
Expected: all green across the whole plugin suite.

- [ ] **Step 5: Commit**

```bash
git add plugins/support-tools/src/index.ts plugins/support-tools/tests/index.test.ts
git commit -m "feat(support-tools): register profile_status (tool count 4 -> 5)"
```

---

## Task 6: Remove `jan@muso.ai` from outbound email allowlist

**Files:**
- Modify: `plugins/intercom/src/sanitize-email.ts`
- Modify: `plugins/intercom/tests/sanitize-email.test.ts`

- [ ] **Step 1: Write failing test**

Add to `plugins/intercom/tests/sanitize-email.test.ts`:

```typescript
it("scrubs jan@muso.ai (removed from allowlist 2026-05-11)", () => {
  const result = sanitizeOutboundBody("Email Jan at jan@muso.ai for help.");
  expect(result.body).toBe("Email Jan at support@muso.ai for help.");
  expect(result.redactions).toEqual(["jan@muso.ai"]);
});

it("allows support@muso.ai unchanged", () => {
  const result = sanitizeOutboundBody("Email support@muso.ai.");
  expect(result.body).toBe("Email support@muso.ai.");
  expect(result.redactions).toEqual([]);
});
```

If existing tests assert that `jan@muso.ai` passes through, **update them** (read the file first to find every such assertion).

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd plugins/intercom && pnpm test sanitize-email
```
Expected: the new "scrubs jan@muso.ai" test fails because `jan@muso.ai` is in the allowlist.

- [ ] **Step 3: Remove from allowlist**

Edit `plugins/intercom/src/sanitize-email.ts`:

```typescript
export const ALLOWED_OUTBOUND_EMAILS: ReadonlySet<string> = new Set([
  "support@muso.ai",
]);
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd plugins/intercom && pnpm test sanitize-email
```
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add plugins/intercom/src/sanitize-email.ts plugins/intercom/tests/sanitize-email.test.ts
git commit -m "fix(intercom): scrub jan@muso.ai in outbound bodies — only support@muso.ai is allowed"
```

---

## Task 7: New `sanitize-tool-leak.ts` deterministic sanitizer

**Files:**
- Create: `plugins/intercom/src/sanitize-tool-leak.ts`
- Create: `plugins/intercom/tests/sanitize-tool-leak.test.ts`

Pure function, modeled after `sanitize-email.ts`. Replaces forbidden tokens with `[REDACTED]` in outbound bodies; returns the cleaned body and the list of redactions for audit logging.

- [ ] **Step 1: Write failing tests**

Create `plugins/intercom/tests/sanitize-tool-leak.test.ts`:

```typescript
import { describe, it, expect } from "vitest";
import { sanitizeToolLeak } from "../src/sanitize-tool-leak.js";

describe("sanitizeToolLeak", () => {
  it("redacts internal tool names", () => {
    const out = sanitizeToolLeak("Let me call profile_status to check your account.");
    expect(out.body).toBe("Let me call [REDACTED] to check your account.");
    expect(out.redactions).toContain("profile_status");
  });

  it("redacts create_ticket, profile_lookup, credits_search, subscription_status", () => {
    const out = sanitizeToolLeak("Tools: create_ticket profile_lookup credits_search subscription_status.");
    for (const tok of ["create_ticket", "profile_lookup", "credits_search", "subscription_status"]) {
      expect(out.redactions).toContain(tok);
    }
    expect(out.body).not.toMatch(/profile_lookup|credits_search|subscription_status|create_ticket/);
  });

  it("redacts internal phrases (case-insensitive)", () => {
    const cases = [
      "Tool failed to fetch your data.",
      "There was an error fetching your data.",
      "Unable to look up your profile.",
      "The system says you're not eligible.",
      "My system can't see that.",
      "There was an issue with the lookup.",
    ];
    for (const c of cases) {
      const out = sanitizeToolLeak(c);
      expect(out.body).toContain("[REDACTED]");
      expect(out.redactions.length).toBeGreaterThan(0);
    }
  });

  it("redacts internal architecture words (case-insensitive)", () => {
    const out = sanitizeToolLeak("We use ClickUp and openclaw on HYDRA.");
    expect(out.body).toBe("We use [REDACTED] and [REDACTED] on [REDACTED].");
    expect(out.redactions).toEqual(expect.arrayContaining(["ClickUp", "openclaw", "HYDRA"]));
  });

  it("passes through approved phrasing unchanged", () => {
    const allow = [
      "I've flagged your profile to engineering.",
      "I'm looking at your profile right now — latest credit is Track A from 2026-05-08.",
      "You'll hear back within 2 business days.",
    ];
    for (const a of allow) {
      const out = sanitizeToolLeak(a);
      expect(out.body).toBe(a);
      expect(out.redactions).toEqual([]);
    }
  });

  it("handles non-string body defensively", () => {
    // @ts-expect-error testing runtime safety
    const out = sanitizeToolLeak(null);
    expect(out.body).toBe("[REDACTED]");
    expect(out.redactions[0]).toMatch(/non-string body/);
  });

  it("truncates pathological input", () => {
    const big = "openclaw ".repeat(5000); // > 16k bytes
    const out = sanitizeToolLeak(big);
    expect(out.body.length).toBeLessThanOrEqual(16_000);
    expect(out.redactions.some((r) => r.includes("truncated"))).toBe(true);
  });
});
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd plugins/intercom && pnpm test sanitize-tool-leak
```
Expected: all fail (module not found).

- [ ] **Step 3: Implement the sanitizer**

Create `plugins/intercom/src/sanitize-tool-leak.ts`:

```typescript
/**
 * Mechanical outbound tool-leak guardrail for the Intercom CS agent.
 *
 * Customer-facing replies must not contain internal tool names, architecture
 * terms, or "the system says…" phrasing. This sanitizer is the deterministic
 * enforcement layer — SOUL.md prose is paired instruction-layer defense, not
 * the guarantee. Mirrors the shape of sanitize-email.ts so the wrapper in
 * outbound.ts can compose both predictably.
 */

export interface ToolLeakSanitizeResult {
  body: string;
  redactions: string[];
}

const REDACTED = "[REDACTED]";
const MAX_BODY_LENGTH = 16_000;

const PATTERNS: RegExp[] = [
  // tool tokens
  /\bprofile_status\b/g,
  /\bprofile_lookup\b/g,
  /\bcredits_search\b/g,
  /\bcreate_ticket\b/g,
  /\bsubscription_status\b/g,
  // internal phrases (case-insensitive)
  /\btool failed\b/gi,
  /\berror fetching\b/gi,
  /\bunable to look up\b/gi,
  /\bthe system says\b/gi,
  /\bmy system\b/gi,
  /\bthere was an issue with\b/gi,
  // architecture words (case-insensitive)
  /\bClickUp\b/gi,
  /\bopenclaw\b/gi,
  /\bHYDRA\b/g, // case-sensitive: avoid clobbering legitimate names like "hydra" if any appear
];

export function sanitizeToolLeak(body: string): ToolLeakSanitizeResult {
  if (typeof body !== "string") {
    return { body: REDACTED, redactions: [`<non-string body: ${typeof body}>`] };
  }
  const truncated = body.length > MAX_BODY_LENGTH;
  let input = truncated ? body.slice(0, MAX_BODY_LENGTH) : body;
  const redactions: string[] = [];
  for (const pat of PATTERNS) {
    input = input.replace(pat, (match) => {
      redactions.push(match);
      return REDACTED;
    });
  }
  if (truncated) redactions.push(`<truncated: ${body.length} -> ${MAX_BODY_LENGTH} bytes>`);
  return { body: input, redactions };
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd plugins/intercom && pnpm test sanitize-tool-leak
```
Expected: green.

- [ ] **Step 5: Commit**

```bash
git add plugins/intercom/src/sanitize-tool-leak.ts plugins/intercom/tests/sanitize-tool-leak.test.ts
git commit -m "feat(intercom): add sanitize-tool-leak.ts deterministic outbound sanitizer for internal tool names + architecture terms"
```

---

## Task 8: Wire tool-leak sanitizer into `SanitizingIntercomClient`

**Files:**
- Modify: `plugins/intercom/src/outbound.ts`
- Modify: `plugins/intercom/tests/outbound.test.ts`

The wrapper runs both sanitizers on every outbound body; either layer's redactions trigger an audit log row.

- [ ] **Step 1: Write failing test**

Add to `plugins/intercom/tests/outbound.test.ts`:

```typescript
it("scrubs tool-leak tokens via SanitizingIntercomClient", async () => {
  const inner = new MockIntercomClient();
  const log = { error: vi.fn() };
  const client = new SanitizingIntercomClient(inner, log);
  await client.replyToConversation({
    conversationId: "c1",
    adminId: "a",
    body: "Let me call profile_status — actually I'll just check.",
  });
  expect(inner.calls.replyToConversation[0].body).not.toContain("profile_status");
  expect(inner.calls.replyToConversation[0].body).toContain("[REDACTED]");
  expect(log.error).toHaveBeenCalledWith(expect.stringContaining("[intercom:tool-leak]"));
});

it("scrubs both email AND tool-leak in one body", async () => {
  const inner = new MockIntercomClient();
  const log = { error: vi.fn() };
  const client = new SanitizingIntercomClient(inner, log);
  await client.replyToConversation({
    conversationId: "c1",
    adminId: "a",
    body: "Email nick@example.com or call profile_lookup directly.",
  });
  const body = inner.calls.replyToConversation[0].body;
  expect(body).not.toMatch(/nick@example\.com|profile_lookup/);
  // expect both audit lines fired
  const lines = (log.error.mock.calls as any[]).map((c) => c[0] as string);
  expect(lines.some((l) => l.includes("[intercom:email-leak]"))).toBe(true);
  expect(lines.some((l) => l.includes("[intercom:tool-leak]"))).toBe(true);
});
```

- [ ] **Step 2: Run tests to confirm they fail**

```bash
cd plugins/intercom && pnpm test outbound
```
Expected: failures — `profile_status` still appears in the outbound body.

- [ ] **Step 3: Wire the sanitizer**

Edit `plugins/intercom/src/outbound.ts`:

a) Add an import at the top, near the email sanitizer import:
```typescript
import { sanitizeToolLeak } from "./sanitize-tool-leak.js";
```

b) Inside `SanitizingIntercomClient.replyToConversation`, after the email-sanitizer block and before the `return this.inner.replyToConversation(...)` call, run the tool-leak sanitizer. Replace the existing body of the method with:

```typescript
async replyToConversation(params: {
  conversationId: string;
  adminId: string;
  body: string;
}): Promise<{ messageId: string }> {
  const emailPass = sanitizeOutboundBody(params.body);
  if (emailPass.redactions.length > 0) {
    const unique = Array.from(new Set(emailPass.redactions));
    const msg = `[intercom:email-leak] conv=${params.conversationId} count=${unique.length} redacted=${JSON.stringify(unique)}`;
    try { this.log?.error?.(msg); } catch { try { console.error(msg); } catch { /* noop */ } }
  }
  const toolPass = sanitizeToolLeak(emailPass.body);
  if (toolPass.redactions.length > 0) {
    const unique = Array.from(new Set(toolPass.redactions));
    const msg = `[intercom:tool-leak] conv=${params.conversationId} count=${unique.length} redacted=${JSON.stringify(unique)}`;
    try { this.log?.error?.(msg); } catch { try { console.error(msg); } catch { /* noop */ } }
  }
  return this.inner.replyToConversation({ ...params, body: toolPass.body });
}
```

- [ ] **Step 4: Run tests to confirm they pass**

```bash
cd plugins/intercom && pnpm test
```
Expected: all green across the intercom plugin suite.

- [ ] **Step 5: Commit**

```bash
git add plugins/intercom/src/outbound.ts plugins/intercom/tests/outbound.test.ts
git commit -m "feat(intercom): wire sanitize-tool-leak into SanitizingIntercomClient — runs after email scrub on every outbound body"
```

---

## Task 9: SOUL.md updates

**Files:**
- Modify: `workspaces/support/SOUL.md`

Three edits, all surgical.

- [ ] **Step 1: Update tool-count header and add `profile_status` entry**

In `workspaces/support/SOUL.md`, find the section starting with `## Allowed Tools (EXACTLY 4 -- nothing else)`. Replace `EXACTLY 4` with `EXACTLY 5`. Immediately after the `4. **create_ticket**` block, insert:

```markdown
5. **profile_status** -- bundled read-only view of a customer's profile (name, role, verified, credits count, latest 3 credits sorted by release_date descending). Use this FIRST whenever a customer mentions analytics, streams, data freshness, or whether their account "is working". Returns structured JSON; never throws.
```

- [ ] **Step 2: Tighten Contact Disclosure section**

Find the section `## Contact Disclosure (CRITICAL)`. Replace the allowed-emails list:

```markdown
The ONLY Muso email address you are ever permitted to share with a customer is:

- `support@muso.ai`

You MUST NOT proactively share `support@muso.ai`. For every human-action need, use `create_ticket`. The ONLY situation in which mentioning `support@muso.ai` is permitted is when `create_ticket` itself returned a failure response (`submitted: false` with `reason != "rate_limited"`) in the current turn — and even then, prefer asking the customer to retry sending their message.

You MUST NOT share any other email address — not an employee's personal address, not a team lead's address, not a billing contact, not an address you recall from any source.
```

Remove the old paragraph that listed both `support@muso.ai` and `jan@muso.ai` as allowed.

- [ ] **Step 3: Add Tool Failure subsection inside Response Patterns**

Find the `## Response Patterns` section and append a new subsection at the end:

```markdown
**Tool Failure**: Tools return structured JSON, never customer-facing English. Translate failures internally:

- `profile_status: { found: false, reason: "no_match" }` — ask one focused follow-up: *"Can you share your Muso profile link or the email on your account?"*
- `profile_status: { found: false, reason: "multiple_matches" }` — ask for the profile URL specifically.
- `profile_status: { found: false, reason: "lookup_unavailable" | "missing_input" | "rate_limited" }` — do NOT mention the lookup. Continue with the KB answer; offer to flag the profile if the customer shares their link.
- `create_ticket: { submitted: true, ticket_id, sla, ... }` — say *"I've flagged your profile to engineering. You'll hear back within `<sla>`."*
- `create_ticket: { submitted: false, reason: "rate_limited" }` — say *"Looks like a request is already on the way to our team for you. You'll hear back soon."*
- `create_ticket: { submitted: false, reason: "queue_busy" }` — ask the customer to retry their message.

Never use these words to the customer: "tool", "lookup", "error", "unavailable", "system", "API", "ticket", "ClickUp", "openclaw", "HYDRA". The outbound sanitizer enforces this mechanically — these words will be redacted from your reply if they slip through.
```

- [ ] **Step 4: Commit**

```bash
git add workspaces/support/SOUL.md
git commit -m "docs(support): SOUL.md — tool count 5, profile_status entry, contact disclosure tightened, Tool Failure subsection"
```

---

## Task 10: TOOLS.md update

**Files:**
- Modify: `workspaces/support/TOOLS.md`

- [ ] **Step 1: Update tool-count statements**

Find the lines (3 and 5 today) that say `## Allowed Tools (EXACTLY 4)` and `Only these 4 tools are permitted.` Replace `4` → `5` in both.

- [ ] **Step 2: Add `profile_status` section**

After the existing `### 4. create_ticket` block, append:

```markdown
### 5. profile_status

- **Bundles**: `GET api.muso.ai/api/c/v5/search/autocomplete` + `GET api.muso.ai/api/c/v4/profile/{id}/credits` (with `/v5/search` fallback when autocomplete is empty)
- **Returns**: Structured JSON. On success: `{ found: true, profile: { id, name, verified, primary_role, credits_count }, latest_credits: [top 3 sorted by release_date desc], latest_credit_date }`. On failure: `{ found: false, reason: "no_match" | "multiple_matches" | "lookup_unavailable" | "missing_input" | "rate_limited", … }`.
- **Auth**: Service API key (handled by plugin, never visible to agent)
- **Rate limit**: 10/min per session
- **Parameters** (one of, precedence top-to-bottom): `profile_id` (UUID), `profile_url` (full credits.muso.ai URL), `email` (used for lookup, never echoed back), `name` (display name)
- **PII filter**: email, phone, address, payment details are NEVER returned
```

- [ ] **Step 3: Commit**

```bash
git add workspaces/support/TOOLS.md
git commit -m "docs(support): TOOLS.md — add profile_status (5th tool)"
```

---

## Task 11: Analytics resolution path in `reference/common-issues.md`

**Files:**
- Modify: `workspaces/support/reference/common-issues.md`

- [ ] **Step 1: Replace the resolution path**

Find the section `## 7. Analytics not showing / streams not updating` (or similarly numbered — search for "Analytics not showing"). Replace the existing numbered resolution steps with:

```markdown
**Resolution path (revised 2026-05-11):**

1. Call `profile_status` with whatever profile signal the customer has provided — profile URL, UUID, name, or email from conversation context. Never echo the email back. Acknowledge what you see, e.g. *"I'm looking at your profile right now — latest credit is `<track>` from `<date>`, showing `<N>` credits on file."* Then deliver the upgrade-in-progress message. Optionally offer to flag the profile.

2. If the customer accepts ("thanks", "ok", "got it"): close out. **No ticket.**

3. If the customer pushes back about **timing or data** (asks for timing again, expresses frustration about staleness, asks "are you actually checking", or "when will MINE update?"): call `create_ticket` with `actionType: "analytics-followup"`. Populate `details` with what `profile_status` returned (profile URL, latest credit date, credits count) and the customer's described symptom. Reply with *"I've flagged your profile to engineering so they can review yours specifically. You'll hear back within `<tool.sla>`."*

4. **If the customer mentions a refund at any point** — even tangentially ("I want my money back", "I'll cancel", "this isn't worth what I paid") — the `refund-retention` skill takes precedence over `analytics-followup`. Run the existing 3-gate retention flow first.

5. **Never tell the customer to email any address.** No `support@muso.ai`, no `jan@muso.ai`, no implication that the conversation needs to move channels. The ticket IS the escalation.
```

- [ ] **Step 2: Update the "Never promise" list at the bottom of section 7**

Add a new bullet to the existing list:

```markdown
- Recommend the customer email any Muso address. The ticket IS the escalation.
```

- [ ] **Step 3: Commit**

```bash
git add workspaces/support/reference/common-issues.md
git commit -m "docs(support): analytics resolution path uses profile_status + analytics-followup ticket, no email handoff"
```

---

## Task 12: output-sanitizer/SKILL.md prompt-level extension

**Files:**
- Modify: `workspaces/support/skills/output-sanitizer/SKILL.md`

Documentation-level mirror of the mechanical sanitizer in Task 7. Caroline avoids producing these tokens; the sanitizer remains the enforcement layer.

- [ ] **Step 1: Extend the blocklist**

Find the blocklist regex sections (Internal System Terms, Infrastructure Terms, Agent/Architecture Terms). Add a new section at the end:

```markdown
**Tool Names and Tool-Failure Phrasing** (case-insensitive):
- `profile_status`
- `profile_lookup`
- `credits_search`
- `subscription_status`
- `create_ticket`
- `tool failed`
- `error fetching`
- `unable to look up`
- `the system says`
- `my system`
- `there was an issue with`

These overlap with the mechanical sanitizer in `plugins/intercom/src/sanitize-tool-leak.ts`. The mechanical layer is the enforcement guarantee; this list is paired instruction-layer defense to prevent the model from emitting them in the first place.
```

- [ ] **Step 2: Commit**

```bash
git add workspaces/support/skills/output-sanitizer/SKILL.md
git commit -m "docs(support): output-sanitizer SKILL.md mirrors the new mechanical tool-leak sanitizer"
```

---

## Task 13: Plugin path drift verification + deploy.sh check

**Files:**
- Inspect: `deploy.sh`

Verify the deploy script copies `plugins/support-tools/` to `/root/.openclaw-edge/extensions/support-tools/`. The directory exists on hydra today (verified during planning), so deploy almost certainly handles it, but confirm before the staging deploy.

- [ ] **Step 1: Grep deploy.sh for the relevant rsync block**

```bash
grep -n "support-tools\|extensions" deploy.sh | head -20
```

Confirm there is a per-profile rsync that includes the support-tools plugin into `/root/.openclaw-edge/extensions/`. If multiple profiles exist (main/edge/dev), confirm all needed targets are covered.

- [ ] **Step 2: If a path is missing, add it**

If the grep above shows the plugin is rsynced only to `/root/.openclaw-main/extensions/` (or only the legacy `/root/.openclaw/extensions/`), add a matching rsync entry pointing to `/root/.openclaw-edge/extensions/support-tools/`. **Reuse the shared excludes array; do not introduce a new ad-hoc rsync invocation without the standard exclude flags — pre-commit `[2/7]` will fail otherwise.**

- [ ] **Step 3: If a change was made, commit**

```bash
git add deploy.sh
git commit -m "fix(deploy): ensure support-tools plugin lands in /root/.openclaw-edge/extensions/"
```

---

## Task 14: Push and open PR

- [ ] **Step 1: Push branch**

```bash
git push -u origin feat/caroline-cs-agent-brainstorm
```

- [ ] **Step 2: Open PR**

```bash
gh pr create --title "feat(support): Caroline analytics handoff — load support-tools on edge, profile_status, analytics-followup ticket, sanitizer" --body "$(cat <<'EOF'
## Summary
- P0: enable `support-tools` plugin on edge gateway (was never registered — Caroline currently has zero custom tools at runtime)
- new `profile_status` tool (bundled read-only profile + latest 3 credits)
- `create_ticket` returns structured JSON; new `analytics-followup` actionType
- `jan@muso.ai` removed from outbound email allowlist (code, not just docs)
- new `sanitize-tool-leak.ts` outbound sanitizer for internal tool names + architecture terms
- SOUL.md / TOOLS.md / common-issues.md updates aligning the model contract with the new tool surface

Spec: `docs/superpowers/specs/2026-05-11-caroline-analytics-handoff-design.md`
Plan: `docs/superpowers/plans/2026-05-11-caroline-analytics-handoff.md`

## Test plan
- [ ] vitest passes for `plugins/support-tools` and `plugins/intercom`
- [ ] staging deploy: edge gateway restarts cleanly; tool-registration smoke test confirms all 5 support tools registered
- [ ] intercom widget smoke test: analytics question -> `profile_status` called -> per-profile acknowledgment + KB answer
- [ ] pushback flow: `create_ticket` fires with `actionType=analytics-followup`; ClickUp task lands in list 901000600160 with tags `hydra-action-request`, `tier-1`, `analytics-followup`
- [ ] outbound: no `profile_status`, `create_ticket`, `openclaw`, `HYDRA`, `ClickUp` strings in any reply
- [ ] outbound: any reply mentioning `jan@muso.ai` gets scrubbed to `support@muso.ai` + `[intercom:email-leak]` audit row
- [ ] refund precedence: customer mentioning refund routes through `refund-retention` 3-gate flow, not `analytics-followup`
EOF
)"
```

---

## Task 15: Deploy to hydra and run smoke tests

These steps execute on hydra (live OVH), not locally. Coordinate with Nick before deploying — destructive in the sense that the live edge gateway restarts.

- [ ] **Step 1: SSH to hydra**

```bash
ssh -i ~/.ssh/nick_ovh root@40.160.32.80
```

- [ ] **Step 2: Pull and deploy**

```bash
cd /opt/hydra && git fetch origin && git checkout feat/caroline-cs-agent-brainstorm
./deploy.sh
```

- [ ] **Step 3: Restart edge gateway**

```bash
systemctl restart openclaw-gateway-edge.service && systemctl status openclaw-gateway-edge.service --no-pager
```

Confirm `Active: active (running)`.

- [ ] **Step 4: Tool-registration smoke test (GATING)**

```bash
journalctl -u openclaw-gateway-edge.service --since "1 minute ago" -o cat | grep -iE "plugin|registered|tool"
```

Expected output: log lines showing `support-tools` plugin loaded and all 5 tools registered. If absent, send Caroline a Slack DM (#support test channel):

> @caroline what tools do you have access to?

Confirm she names all 5 (`profile_lookup`, `credits_search`, `subscription_status`, `create_ticket`, `profile_status`).

**If this gate fails, stop. Roll back `openclaw-edge.json` changes and investigate before merging.**

- [ ] **Step 5: End-to-end smoke test in intercom**

1. Open the intercom widget on a staging account (or DM Caroline directly).
2. Send: *"my analytics aren't updating, my profile is `<a known credits.muso.ai/profile/...>` URL"*.
3. Confirm Caroline's reply mentions a specific latest-credit date from `profile_status`.
4. Send: *"that's not good enough, when will MINE actually update?"*
5. Confirm the next reply includes the phrase *"flagged your profile to engineering"* and a `2 business days` SLA.
6. Verify a new ClickUp task in list `901000600160` with tags `hydra-action-request`, `tier-1`, `analytics-followup` and a valid `---ACTION-REQUEST---` JSON block.
7. Grep the reply HTML for forbidden phrases:

```bash
curl -s -H "Authorization: Bearer $MUSOAI_INTERCOM_TOKEN" -H "Intercom-Version: 2.11" \
  "https://api.intercom.io/conversations/<conv-id>?display_as=plaintext" \
  | jq -r '.conversation_parts.conversation_parts[].body' \
  | grep -iE "profile_status|profile_lookup|credits_search|create_ticket|clickup|openclaw|hydra|tool failed|the system says" \
  && echo "LEAK DETECTED" || echo "clean"
```

Expected: `clean`.

- [ ] **Step 6: Refund-precedence smoke test**

1. New intercom conversation: *"my streams aren't updating and I want a refund"*.
2. Confirm Caroline runs the `refund-retention` 3-gate flow (acknowledgment + at least one gate question) before any `create_ticket` fires for `analytics-followup`. The retention flow may end with a `subscription-refund` ticket — that's the correct precedence.

- [ ] **Step 7: Email-allowlist smoke test**

1. Prompt Caroline to share Jan's contact: *"can you give me Jan's email?"*.
2. Confirm her reply does NOT include `jan@muso.ai`. If she emits it, the sanitizer scrubs it to `support@muso.ai` and a `[intercom:email-leak]` audit line appears in the journal:

```bash
journalctl -u openclaw-gateway-edge.service --since "5 min ago" -o cat | grep "intercom:email-leak"
```

- [ ] **Step 8: Merge the PR**

If steps 4–7 pass, merge via `gh pr merge` (or via the GitHub UI). Watch the first hour of edge logs for any unexpected `[intercom:tool-leak]` or `[intercom:email-leak]` audit lines.

---

## Self-Review Notes

**Spec coverage:** All sections of the spec map to a task above. Prerequisites → Task 1. Component 1 (`profile_status`) → Tasks 4, 5. Component 2 (`create_ticket` refactor + `analytics-followup`) → Tasks 2, 3. Component 3 (SOUL/KB) → Tasks 9, 10, 11, 12. Error handling Layer 1 (no-throw) baked into Tasks 4 + 2. Layer 2 (SOUL Tool Failure) → Task 9 step 3. Layer 3 (deterministic outbound sanitizer) → Tasks 6, 7, 8. Testing → tests inside each plugin task + Tasks 14–15 smoke. Rollout commit order matches spec. Observability — read journalctl + ClickUp filters described inline.

**Type/name consistency:** `profile_status` is the canonical tool name throughout — never `profileStatus` or `profile-status`. `analytics-followup` is the canonical actionType — never `analytics_followup`. `TIER_SLAS[1]` = `"2 business days"` everywhere it appears.

**Plugin config secret-ref schema in Task 1 Step 5 may need adjustment** — verify against `openclaw-main.json`'s existing `plugins.entries` block before applying. If the main profile uses a different shape, mirror that one.
