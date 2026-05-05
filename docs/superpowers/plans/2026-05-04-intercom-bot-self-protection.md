# Intercom Bot Self-Protection Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the Intercom AI agent from looping on frustrated users. Replace the narrow regex escalation with a hybrid risk detector (broadened rules + LLM-judge), pin known facts on session state so the bot stops re-asking, add a magic-keyword skip, replace theatrical ticket promises with real ClickUp tickets on every handoff, and add SOUL.md honesty rules.

**Architecture:** Five units inside `plugins/intercom/src/`. `escalation.ts` extended (legacy `checkEscalation` kept; new `assessRisk` added behind feature flag). New: `extractors.ts`, `escalation-action.ts`. `handler.ts` + `channel.ts` extended to wire it all up. Single config flag `riskAssessment.enabled` on the plugin gates the new path.

**Tech Stack:** TypeScript / Node 20 / Vitest. OpenRouter (existing) for the LLM-judge. ClickUp v2 REST API for tickets.

**Spec:** `docs/2026-05-04-intercom-bot-self-protection-design.md`

---

## File Structure

| File | Action | Responsibility |
|------|--------|----------------|
| `plugins/intercom/src/types.ts` | extend | Add `RiskAssessment`, `KnownFacts`; extend `IntercomSessionState` with 3 optional fields; add `IntercomAccountConfig.clickup` block + `IntercomAccountConfig.riskAssessment` block. |
| `plugins/intercom/src/state-store.ts` | extend | Backward-compat deserialization defaults for the 3 new session fields. |
| `plugins/intercom/src/extractors.ts` | **create** | Pure functions: regex extract email + Muso profile URL → derive profile ID. Pure data in/out. |
| `plugins/intercom/src/escalation.ts` | extend | Keep `checkEscalation` (legacy). Add `assessRisk(message, history, state, deps)` with Layer 0 (magic keyword), Layer 1 (broadened rules + turn count), Layer 2 (LLM-judge). |
| `plugins/intercom/src/escalation-action.ts` | **create** | `executeEscalation(state, conversationId, assessment, deps)` — orchestrates dedupe-gate, ticket, farewell, reassign, Slack ping. |
| `plugins/intercom/src/handler.ts` | extend | Call extractor, increment `userTurnCount`, call `assessRisk` under flag, return `{action: "escalate"}` with full assessment. |
| `plugins/intercom/src/channel.ts` | extend | Inline-prepend `[CONVERSATION_CONTEXT]` block to `rawBody` before dispatch. Replace inline escalation block with call to `executeEscalation`. Outbound sanitization pass strips `[CONVERSATION_CONTEXT]` if model regurgitates. |
| `plugins/intercom/src/config.ts` | extend | Validate the new config fields (ClickUp creds, riskAssessment block). |
| `plugins/intercom/tests/extractors.test.ts` | **create** | Unit tests for the pure extractors. |
| `plugins/intercom/tests/escalation.test.ts` | extend | New tests for `assessRisk` (rules, magic keyword, turn-count, judge mock). |
| `plugins/intercom/tests/escalation-action.test.ts` | **create** | Unit tests for orchestrator: dedupe order, ticket fail farewell, reassign-conflict tolerance. |
| `plugins/intercom/tests/handler.test.ts` | extend | Tests for turn counter increment + handoff dispatch + flag-off legacy path. |
| `plugins/intercom/tests/channel.test.ts` | extend | Test for `[CONVERSATION_CONTEXT]` injection + outbound strip. |
| `workspaces/support/SOUL.md` | extend | Add "Honesty rules (no fabrication)" section + `[CONVERSATION_CONTEXT]` directive. |
| `openclaw-main.json` | extend | Enable `support-tools` plugin; add `create_ticket` to support-agent tool allowlist; populate intercom plugin's `clickup` + `riskAssessment` blocks. |

---

## Task 1: Extend types — `RiskAssessment`, `KnownFacts`, session state fields, config blocks

**Files:**
- Modify: `plugins/intercom/src/types.ts`

- [ ] **Step 1: Add new types and extend existing interfaces.**

Open `plugins/intercom/src/types.ts` and add the new types **before** the `// --- Constants ---` comment, and extend `IntercomSessionState` and `IntercomAccountConfig` in place:

```ts
// --- Pinned facts ---

export interface KnownFacts {
  accountEmail?: string;
  musoProfileUrl?: string;
  musoProfileId?: string;
  planTier?: "Pro" | "Business" | "Free" | "unknown";
  primaryComplaint?: string;
  factsLastUpdated?: string;
}

// --- Risk assessment (replaces narrow EscalationResult for the new path) ---

export type RiskSource = "user_request" | "rule" | "judge";

export type RiskActionType =
  | "subscription-refund"
  | "dispute"
  | "support-general";

export interface RiskAssessment {
  triggered: boolean;
  source?: RiskSource;
  reason?: string;            // e.g. "user_requested_human", "refund_intent", "frustration"
  matchedPattern?: string;    // for rule layer; for judge layer this is the joined `reasons` list
  suggestedActionType?: RiskActionType;
  confidence?: "low" | "medium" | "high";
}
```

Then extend `IntercomSessionState` (line 86) — add three optional fields just before the closing brace:

```ts
export interface IntercomSessionState {
  conversationId: string;
  workspaceId: string;
  handoffMode: HandoffMode;
  lifecycleState: LifecycleState;
  currentAssigneeId: string | null;
  currentAssigneeType: AssigneeType | null;
  lastEventId: string | null;
  processedEventIds: string[];
  outboundMessageIds: string[];
  createdAt: string;
  updatedAt: string;
  // New, all optional for backward-compat with on-disk state
  knownFacts?: KnownFacts;
  escalationFiredAt?: string | null;
  userTurnCount?: number;
}
```

Then extend `IntercomAccountConfig` (line 102) — add two optional blocks just before the closing brace:

```ts
export interface IntercomAccountConfig {
  enabled: boolean;
  workspaceId: string;
  token: string;
  webhookSecret: string;
  botAdminId: string;
  defaultInboxId: string;
  fallbackSlackSupervisionChannel: string;
  fallbackAcknowledgement: string;
  requireMappedHumanAdmin: boolean;
  adminMapping: Record<string, string>;
  // New — gates the bot self-protection layer. Default OFF for backward-compat.
  riskAssessment?: {
    enabled: boolean;
    judgeModel?: string;             // default: "anthropic/claude-haiku-4-5-20251001"
    judgeMinTurnCount?: number;      // default: 4
    turnCountHardCap?: number;       // default: 6 (i.e. > 6 = forced handoff)
  };
  // New — ClickUp creds for auto-ticket creation on handoff. All optional;
  // missing creds means tickets won't be filed (handoff still proceeds with
  // degraded farewell text).
  clickup?: {
    apiKey: string;
    listId: string;
    userEmailFieldId: string;
    profileIdFieldId: string;
  };
}
```

- [ ] **Step 2: Confirm the file still compiles.**

Run: `cd plugins/intercom && pnpm exec tsc --noEmit`
Expected: zero errors.

- [ ] **Step 3: Commit.**

```bash
git add plugins/intercom/src/types.ts
git commit -m "feat(intercom): add RiskAssessment + KnownFacts + session/config extensions

Foundation types for bot self-protection. All new fields are optional;
on-disk session state and existing config keep loading without migration.
Behavior unchanged in this commit."
```

---

## Task 2: Extend `state-store.ts` deserialization with defaults

The existing loader (line 53) does `inner.set(convId, state)` directly. New optional fields will be `undefined` on old entries, which TypeScript's optional-property typing already permits, but a few call sites (e.g. `state.userTurnCount += 1`) need defaults to avoid `NaN`. Centralize the defaulting on load.

**Files:**
- Modify: `plugins/intercom/src/state-store.ts:50-58`
- Test: `plugins/intercom/tests/state-store.test.ts` (extend)

- [ ] **Step 1: Write the failing test for backward-compat defaulting on load.**

Append this test to `plugins/intercom/tests/state-store.test.ts`:

```ts
import { describe, it, expect, beforeEach } from "vitest";
import { mkdtemp, writeFile } from "node:fs/promises";
import { tmpdir } from "node:os";
import { join } from "node:path";
import { initStateStore, loadSessions } from "../src/state-store.js";

describe("state-store backward-compat defaults", () => {
  let dir: string;

  beforeEach(async () => {
    dir = await mkdtemp(join(tmpdir(), "intercom-state-"));
  });

  it("defaults userTurnCount to 0 and escalationFiredAt to null when missing from on-disk state", async () => {
    await initStateStore(dir);
    const filePath = join(dir, "plugins", "intercom", "sessions.json");
    const legacy = {
      version: 1,
      sessions: {
        acct1: {
          conv1: {
            conversationId: "conv1",
            workspaceId: "ws1",
            handoffMode: "agent_active",
            lifecycleState: "open",
            currentAssigneeId: null,
            currentAssigneeType: null,
            lastEventId: null,
            processedEventIds: [],
            outboundMessageIds: [],
            createdAt: "2026-01-01T00:00:00Z",
            updatedAt: "2026-01-01T00:00:00Z",
          },
        },
      },
    };
    await writeFile(filePath, JSON.stringify(legacy), "utf8");

    const loaded = await loadSessions();
    const state = loaded.get("acct1")!.get("conv1")!;

    expect(state.userTurnCount).toBe(0);
    expect(state.escalationFiredAt).toBeNull();
    expect(state.knownFacts).toEqual({});
  });
});
```

- [ ] **Step 2: Run the test, confirm it fails.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/state-store.test.ts -t "backward-compat"`
Expected: FAIL — `state.userTurnCount` is `undefined`, not `0`.

- [ ] **Step 3: Add defaults inside `loadSessions()`.**

In `plugins/intercom/src/state-store.ts`, replace lines 50-58 with:

```ts
  const result = new Map<string, Map<string, IntercomSessionState>>();
  const sessions = parsed.sessions ?? {};
  for (const [accountId, convMap] of Object.entries(sessions)) {
    const inner = new Map<string, IntercomSessionState>();
    for (const [convId, state] of Object.entries(convMap as Record<string, IntercomSessionState>)) {
      // Backward-compat: default new optional fields if missing from on-disk state.
      if (state.userTurnCount === undefined) state.userTurnCount = 0;
      if (state.escalationFiredAt === undefined) state.escalationFiredAt = null;
      if (state.knownFacts === undefined) state.knownFacts = {};
      inner.set(convId, state);
    }
    result.set(accountId, inner);
  }

  return result;
```

- [ ] **Step 4: Run the test, confirm it passes.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/state-store.test.ts -t "backward-compat"`
Expected: PASS.

- [ ] **Step 5: Run the full state-store test file to confirm no regressions.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/state-store.test.ts`
Expected: all tests pass.

- [ ] **Step 6: Commit.**

```bash
git add plugins/intercom/src/state-store.ts plugins/intercom/tests/state-store.test.ts
git commit -m "feat(intercom): backward-compat defaults for new session fields"
```

---

## Task 3: Create `extractors.ts` — pure pinned-fact extractors

**Files:**
- Create: `plugins/intercom/src/extractors.ts`
- Create: `plugins/intercom/tests/extractors.test.ts`

- [ ] **Step 1: Write the failing tests for the extractor.**

Create `plugins/intercom/tests/extractors.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { updateKnownFacts } from "../src/extractors.js";
import type { KnownFacts } from "../src/types.js";

describe("updateKnownFacts", () => {
  it("extracts an email address and pins accountEmail", () => {
    const out = updateKnownFacts("you can reach me at jami@jamigrooms.com", {});
    expect(out.accountEmail).toBe("jami@jamigrooms.com");
  });

  it("normalizes email to lowercase", () => {
    const out = updateKnownFacts("Jami@JamiGrooms.COM", {});
    expect(out.accountEmail).toBe("jami@jamigrooms.com");
  });

  it("does not overwrite an existing accountEmail", () => {
    const prev: KnownFacts = { accountEmail: "first@example.com" };
    const out = updateKnownFacts("contact me at second@example.com", prev);
    expect(out.accountEmail).toBe("first@example.com");
  });

  it("extracts a Muso profile URL and derives the profile ID", () => {
    const out = updateKnownFacts(
      "see my profile https://muso.ai/profile/abc123-def456-789",
      {},
    );
    expect(out.musoProfileUrl).toBe("https://muso.ai/profile/abc123-def456-789");
    expect(out.musoProfileId).toBe("abc123-def456-789");
  });

  it("returns the input unchanged when no facts are present in the message", () => {
    const prev: KnownFacts = { accountEmail: "x@y.com" };
    const out = updateKnownFacts("hello there", prev);
    expect(out).toEqual({ ...prev, factsLastUpdated: out.factsLastUpdated });
  });

  it("sets factsLastUpdated when a fact is updated", () => {
    const before = Date.now();
    const out = updateKnownFacts("foo@bar.com", {});
    const ts = Date.parse(out.factsLastUpdated!);
    expect(ts).toBeGreaterThanOrEqual(before);
  });
});
```

- [ ] **Step 2: Run, confirm fail.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/extractors.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Create the extractor module.**

Create `plugins/intercom/src/extractors.ts`:

```ts
import type { KnownFacts } from "./types.js";

// Reuse the same email pattern shape as sanitize-email.ts for consistency.
// Anchored on word boundaries to avoid greedy matches across whitespace.
const EMAIL_PATTERN = /\b[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}\b/;

// Muso profile URLs look like https://muso.ai/profile/<uuid-or-hex-id>.
// We accept any path segment of >=8 chars made of [a-z0-9-] (Muso uses
// UUIDs but older links may use hex). Capture the trailing segment.
const PROFILE_URL_PATTERN = /(https?:\/\/muso\.ai\/profile\/([a-zA-Z0-9-]{8,}))/i;

const MAX_BODY_LENGTH = 16_000; // mirror sanitize-email.ts protection

export function updateKnownFacts(message: string, current: KnownFacts): KnownFacts {
  if (typeof message !== "string" || message.length === 0) {
    return current;
  }
  const input = message.length > MAX_BODY_LENGTH ? message.slice(0, MAX_BODY_LENGTH) : message;

  const next: KnownFacts = { ...current };
  let changed = false;

  if (!next.accountEmail) {
    const m = input.match(EMAIL_PATTERN);
    if (m) {
      next.accountEmail = m[0].toLowerCase();
      changed = true;
    }
  }

  if (!next.musoProfileUrl) {
    const m = input.match(PROFILE_URL_PATTERN);
    if (m) {
      next.musoProfileUrl = m[1];
      next.musoProfileId = m[2];
      changed = true;
    }
  }

  if (changed) {
    next.factsLastUpdated = new Date().toISOString();
  }

  return next;
}
```

- [ ] **Step 4: Run, confirm pass.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/extractors.test.ts`
Expected: all 6 tests pass.

- [ ] **Step 5: Commit.**

```bash
git add plugins/intercom/src/extractors.ts plugins/intercom/tests/extractors.test.ts
git commit -m "feat(intercom): pinned-fact extractors (email + Muso profile)"
```

---

## Task 4: Extend `escalation.ts` — add `assessRisk` Layer 0 + Layer 1 (rules)

The legacy `checkEscalation()` stays exported. Add a new `assessRisk()` that does broadened rules + turn-count + magic keyword. Layer 2 (LLM-judge) is added in Task 5.

**Files:**
- Modify: `plugins/intercom/src/escalation.ts`
- Modify: `plugins/intercom/tests/escalation.test.ts`

- [ ] **Step 1: Write failing tests for `assessRisk` Layers 0–1.**

Append to `plugins/intercom/tests/escalation.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { assessRisk } from "../src/escalation.js";
import type { IntercomSessionState } from "../src/types.js";

const baseState: IntercomSessionState = {
  conversationId: "conv1",
  workspaceId: "ws1",
  handoffMode: "agent_active",
  lifecycleState: "open",
  currentAssigneeId: null,
  currentAssigneeType: null,
  lastEventId: null,
  processedEventIds: [],
  outboundMessageIds: [],
  createdAt: "",
  updatedAt: "",
  userTurnCount: 1,
  escalationFiredAt: null,
  knownFacts: {},
};

const noJudge = { judge: undefined };

describe("assessRisk Layer 0 (magic keyword)", () => {
  it("fires on 'talk to a human'", async () => {
    const r = await assessRisk("can i talk to a human please", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.source).toBe("user_request");
    expect(r.reason).toBe("user_requested_human");
    expect(r.confidence).toBe("high");
  });

  it("fires on 'real person'", async () => {
    const r = await assessRisk("i need a real person", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.source).toBe("user_request");
  });

  it("is case-insensitive", async () => {
    const r = await assessRisk("TALK TO A HUMAN", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
  });
});

describe("assessRisk Layer 1 (rules)", () => {
  it("fires on 'refund' → suggestedActionType subscription-refund", async () => {
    const r = await assessRisk("i want a refund", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.source).toBe("rule");
    expect(r.reason).toBe("refund_intent");
    expect(r.suggestedActionType).toBe("subscription-refund");
  });

  it("fires on 'cancel my account' → cancel_intent", async () => {
    const r = await assessRisk("close my account", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("cancel_intent");
  });

  it("fires on 'fraud' → fraud_complaint dispute", async () => {
    const r = await assessRisk("this is fraud", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("fraud_complaint");
    expect(r.suggestedActionType).toBe("dispute");
  });

  it("fires on 'BBB'", async () => {
    const r = await assessRisk("i'll report you to BBB", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
  });

  it("fires on 'going to YouTube' → public_shaming_intent", async () => {
    const r = await assessRisk("i'm posting this on youtube", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("public_shaming_intent");
  });

  it("fires legacy 'lawyer' rule under reason legal_threat", async () => {
    const r = await assessRisk("i'm getting a lawyer", [], baseState, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("legal_threat");
  });

  it("fires turn-count cap at userTurnCount > 6", async () => {
    const stateAtCap = { ...baseState, userTurnCount: 7 };
    const r = await assessRisk("just any reply", [], stateAtCap, noJudge);
    expect(r.triggered).toBe(true);
    expect(r.reason).toBe("turn_count_cap");
  });

  it("does not fire turn-count cap when escalationFiredAt is already set", async () => {
    const already = { ...baseState, userTurnCount: 7, escalationFiredAt: "2026-05-04T00:00:00Z" };
    const r = await assessRisk("any reply", [], already, noJudge);
    expect(r.triggered).toBe(false);
  });

  it("does not fire on benign messages", async () => {
    const r = await assessRisk("hi just checking in", [], baseState, noJudge);
    expect(r.triggered).toBe(false);
  });
});
```

- [ ] **Step 2: Run, confirm fail (export missing).**

Run: `cd plugins/intercom && pnpm exec vitest run tests/escalation.test.ts -t "assessRisk"`
Expected: FAIL — `assessRisk is not a function`.

- [ ] **Step 3: Implement Layers 0 + 1 in `escalation.ts`.**

Replace `plugins/intercom/src/escalation.ts` ENTIRELY with:

```ts
import type {
  EscalationResult,
  IntercomSessionState,
  RiskAssessment,
  RiskActionType,
} from "./types.js";

// ============================================================================
// Layer 0: Magic-keyword consent — explicit "talk to a human" requests.
// ============================================================================
const MAGIC_KEYWORD_PATTERNS: RegExp[] = [
  /\btalk to a (human|person|real|agent)\b/i,
  /\bi want a human\b/i,
  /\bhuman please\b/i,
  /\breal person\b/i,
  /\bspeak to (someone|a person)\b/i,
  /\bagent please\b/i,
];

function checkMagicKeyword(message: string): boolean {
  return MAGIC_KEYWORD_PATTERNS.some((p) => p.test(message));
}

// ============================================================================
// Layer 1: Broadened rules. Each rule maps to a `reason` and a
// `suggestedActionType` for the eventual ClickUp ticket.
// ============================================================================
interface RiskRule {
  reason: string;
  actionType: RiskActionType;
  patterns: RegExp[];
}

const RISK_RULES: RiskRule[] = [
  {
    reason: "refund_intent",
    actionType: "subscription-refund",
    patterns: [
      /\brefund\b/i,
      /\bmoney back\b/i,
      /\bpro[ -]rate\b/i,
      /\bchargeback\b/i,
      /\bbilling dispute\b/i,
      /\binvoice dispute\b/i,
      /\bunauthorized charge\b/i,
    ],
  },
  {
    reason: "cancel_intent",
    actionType: "subscription-refund",
    patterns: [
      /\bcancel(?:l?ing|l?ed|lation)?\b/i,
      /\bunsubscribe\b/i,
      /\bclose (my )?account\b/i,
      /\bdelete (my )?account\b/i,
    ],
  },
  {
    reason: "fraud_complaint",
    actionType: "dispute",
    patterns: [
      /\bfraud(?:ulent)?\b/i,
      /\brip[ -]?off\b/i,
      /\bscam\b/i,
      /\breport (you|this) to\b/i,
      /\bbbb\b/i,
      /\bbetter business bureau\b/i,
    ],
  },
  {
    reason: "public_shaming_intent",
    actionType: "support-general",
    patterns: [
      /\btell (everyone|my friends|everybody)\b/i,
      /\bsocial media\b/i,
      /\byoutube\b/i,
      /\btwitter\b/i,
      /\bx\.com\b/i,
      /\binstagram\b/i,
      /\btiktok\b/i,
      /\bscorched earth\b/i,
      /\bgoing public\b/i,
    ],
  },
  {
    reason: "legal_threat",
    actionType: "dispute",
    patterns: [
      /\blawyer\b/i,
      /\battorney\b/i,
      /\blawsuit\b/i,
      /\bsue\b/i,
      /\bcourt\b/i,
      /\bsubpoena\b/i,
      /\blegal action\b/i,
      /\blegal threat\b/i,
    ],
  },
  {
    reason: "security_incident",
    actionType: "support-general",
    patterns: [
      /\bhacked\b/i,
      /\bcompromised\b/i,
      /\bunauthorized access\b/i,
      /\bstolen account\b/i,
      /\bpassword breach\b/i,
    ],
  },
  {
    reason: "abuse_report",
    actionType: "support-general",
    patterns: [
      /\bharassment\b/i,
      /\babuse report\b/i,
      /\bthreatening\b/i,
      /\bphishing\b/i,
    ],
  },
];

function checkRules(message: string): { reason: string; actionType: RiskActionType; matched: string } | null {
  for (const rule of RISK_RULES) {
    for (const p of rule.patterns) {
      if (p.test(message)) {
        return { reason: rule.reason, actionType: rule.actionType, matched: p.source };
      }
    }
  }
  return null;
}

// ============================================================================
// Public API: legacy + new
// ============================================================================

// Legacy export — used when `riskAssessment.enabled` is false. Do NOT remove
// until rollout step 6 in the spec.
export function checkEscalation(message: string): EscalationResult {
  if (!message) return { triggered: false };
  const m = checkRules(message);
  if (m) {
    // Map new reason names back to the old "category" buckets for backward compat.
    const category =
      m.reason === "refund_intent" || m.reason === "cancel_intent" ? "billing" :
      m.reason === "legal_threat" ? "legal" :
      m.reason === "security_incident" ? "security" :
      m.reason === "abuse_report" ? "abuse" :
      m.reason;
    return { triggered: true, category, matchedPattern: m.matched };
  }
  return { triggered: false };
}

// New export — full hybrid assessment.
export interface AssessRiskDeps {
  judge?: (input: JudgeInput) => Promise<JudgeOutput | null>; // Layer 2 — wired in Task 5
  judgeMinTurnCount?: number;     // default 4
  turnCountHardCap?: number;      // default 6
}

export interface JudgeInput {
  knownFacts: import("./types.js").KnownFacts;
  recentParts: { author: "user" | "bot"; body: string }[];
  currentMessage: string;
}

export interface JudgeOutput {
  shouldHandoff: boolean;
  reasons: string[];
  suggestedActionType: RiskActionType;
  confidence: "low" | "medium" | "high";
}

export async function assessRisk(
  message: string,
  recentParts: JudgeInput["recentParts"],
  state: IntercomSessionState,
  deps: AssessRiskDeps,
): Promise<RiskAssessment> {
  if (!message) return { triggered: false };

  // Layer 0 — magic keyword. Always wins; bypasses dedupe gate (caller's responsibility).
  if (checkMagicKeyword(message)) {
    return {
      triggered: true,
      source: "user_request",
      reason: "user_requested_human",
      suggestedActionType: "support-general",
      confidence: "high",
    };
  }

  // Layer 1a — content rules.
  const ruleHit = checkRules(message);
  if (ruleHit) {
    return {
      triggered: true,
      source: "rule",
      reason: ruleHit.reason,
      matchedPattern: ruleHit.matched,
      suggestedActionType: ruleHit.actionType,
      confidence: "high",
    };
  }

  // Layer 1b — turn-count cap. If we've already fired, do not fire again.
  const cap = deps.turnCountHardCap ?? 6;
  const turns = state.userTurnCount ?? 0;
  if (turns > cap && !state.escalationFiredAt) {
    return {
      triggered: true,
      source: "rule",
      reason: "turn_count_cap",
      suggestedActionType: "support-general",
      confidence: "medium",
    };
  }

  // Layer 2 — LLM judge. Wired in Task 5; if no judge dep is supplied, do nothing.
  const minTurns = deps.judgeMinTurnCount ?? 4;
  if (deps.judge && turns >= minTurns && !state.escalationFiredAt) {
    try {
      const out = await deps.judge({
        knownFacts: state.knownFacts ?? {},
        recentParts,
        currentMessage: message,
      });
      if (out && out.shouldHandoff && out.confidence !== "low") {
        return {
          triggered: true,
          source: "judge",
          reason: out.reasons.join(","),
          suggestedActionType: out.suggestedActionType,
          confidence: out.confidence,
        };
      }
    } catch (err) {
      // Fail-closed — never punish the user for our infra failure.
      console.warn(`[intercom:risk] judge call failed: ${err}`);
    }
  }

  return { triggered: false };
}
```

- [ ] **Step 4: Run new tests, confirm pass.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/escalation.test.ts -t "assessRisk"`
Expected: all 11 new tests pass.

- [ ] **Step 5: Run all existing escalation tests, confirm no regression in legacy `checkEscalation`.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/escalation.test.ts`
Expected: all tests pass (legacy + new).

- [ ] **Step 6: Commit.**

```bash
git add plugins/intercom/src/escalation.ts plugins/intercom/tests/escalation.test.ts
git commit -m "feat(intercom): hybrid risk assessment Layers 0-1 (magic keyword + broadened rules + turn cap)

assessRisk() coexists with legacy checkEscalation() for the rollout window.
Layer 2 (LLM-judge) lands in the next commit."
```

---

## Task 5: Add Layer 2 (LLM-judge) to `assessRisk`

The judge is a separate small function passed in via `deps`. The plugin's bootstrap (channel.ts) constructs it from config + an OpenRouter HTTP client. Test it via a stubbed judge fn.

**Files:**
- Modify: `plugins/intercom/tests/escalation.test.ts` (extend)
- No production code changes — `assessRisk` already accepts the `judge` dep from Task 4. We only need tests proving the wiring + a separate exported `createJudge` factory.
- Create: helper file `plugins/intercom/src/judge.ts` for the OpenRouter caller.

- [ ] **Step 1: Write failing tests for Layer 2 wiring.**

Append to `plugins/intercom/tests/escalation.test.ts`:

```ts
import type { JudgeOutput } from "../src/escalation.js";

describe("assessRisk Layer 2 (judge)", () => {
  it("calls the judge from the 4th customer turn onwards", async () => {
    const calls: number[] = [];
    const judge = async (): Promise<JudgeOutput> => {
      calls.push(Date.now());
      return { shouldHandoff: true, reasons: ["frustration"], suggestedActionType: "support-general", confidence: "high" };
    };
    const r = await assessRisk("hmm not great", [], { ...baseState, userTurnCount: 4 }, { judge });
    expect(calls.length).toBe(1);
    expect(r.triggered).toBe(true);
    expect(r.source).toBe("judge");
  });

  it("does not call the judge before the 4th turn", async () => {
    let called = false;
    const judge = async (): Promise<JudgeOutput> => {
      called = true;
      return { shouldHandoff: false, reasons: [], suggestedActionType: "support-general", confidence: "high" };
    };
    await assessRisk("eh", [], { ...baseState, userTurnCount: 3 }, { judge });
    expect(called).toBe(false);
  });

  it("does not trigger when judge returns confidence=low", async () => {
    const judge = async (): Promise<JudgeOutput> => ({
      shouldHandoff: true,
      reasons: ["frustration"],
      suggestedActionType: "support-general",
      confidence: "low",
    });
    const r = await assessRisk("hmm", [], { ...baseState, userTurnCount: 5 }, { judge });
    expect(r.triggered).toBe(false);
  });

  it("fail-closed: judge throws → no handoff", async () => {
    const judge = async (): Promise<JudgeOutput> => {
      throw new Error("rate limited");
    };
    const r = await assessRisk("hmm", [], { ...baseState, userTurnCount: 5 }, { judge });
    expect(r.triggered).toBe(false);
  });

  it("does not call the judge if rules already fired", async () => {
    let called = false;
    const judge = async (): Promise<JudgeOutput> => {
      called = true;
      return { shouldHandoff: true, reasons: [], suggestedActionType: "support-general", confidence: "high" };
    };
    const r = await assessRisk("i want a refund", [], { ...baseState, userTurnCount: 5 }, { judge });
    expect(called).toBe(false);
    expect(r.source).toBe("rule");
  });
});
```

- [ ] **Step 2: Run, confirm pass (the wiring already exists in Task 4 code).**

Run: `cd plugins/intercom && pnpm exec vitest run tests/escalation.test.ts -t "Layer 2"`
Expected: all 5 tests pass.

- [ ] **Step 3: Create `plugins/intercom/src/judge.ts` — the OpenRouter caller factory.**

```ts
import type { JudgeInput, JudgeOutput, AssessRiskDeps } from "./escalation.js";

const JUDGE_SYSTEM_PROMPT = `You are a customer-support quality monitor. Given the recent
conversation between a paying user and an AI support agent, decide if the conversation
should be handed off to a human teammate now. Score quietly — most conversations should
NOT be handed off. Only recommend handoff when the user is clearly frustrated, asking
the same thing repeatedly without resolution, demanding refunds/cancellation, threatening
public escalation (BBB, social media), or stuck in a loop.

Respond with strict JSON only, matching this schema exactly:
{
  "shouldHandoff": boolean,
  "reasons": string[],          // pick from: "frustration", "repeated_question", "stuck_in_loop", "refund_intent", "cancel_intent", "public_shaming_intent", "ambiguous"
  "suggestedActionType": "subscription-refund" | "dispute" | "support-general",
  "confidence": "low" | "medium" | "high"
}

No prose, no commentary, just JSON.`;

export interface JudgeFactoryDeps {
  openrouterApiKey: string;
  model: string;
  fetchImpl?: typeof fetch;
  timeoutMs?: number;
}

export function createOpenRouterJudge(deps: JudgeFactoryDeps): AssessRiskDeps["judge"] {
  const fetchImpl = deps.fetchImpl ?? fetch;
  const timeoutMs = deps.timeoutMs ?? 8_000;

  return async (input: JudgeInput): Promise<JudgeOutput | null> => {
    const userMsg = JSON.stringify({
      knownFacts: input.knownFacts,
      recentParts: input.recentParts,
      currentMessage: input.currentMessage,
    });

    const ctrl = new AbortController();
    const timer = setTimeout(() => ctrl.abort(), timeoutMs);

    try {
      const res = await fetchImpl("https://openrouter.ai/api/v1/chat/completions", {
        method: "POST",
        headers: {
          "Content-Type": "application/json",
          Authorization: `Bearer ${deps.openrouterApiKey}`,
        },
        body: JSON.stringify({
          model: deps.model,
          messages: [
            { role: "system", content: JUDGE_SYSTEM_PROMPT },
            { role: "user", content: userMsg },
          ],
          response_format: { type: "json_object" },
          max_tokens: 300,
          temperature: 0,
        }),
        signal: ctrl.signal,
      });
      if (!res.ok) {
        throw new Error(`openrouter status ${res.status}`);
      }
      const data: any = await res.json();
      const content = data?.choices?.[0]?.message?.content;
      if (typeof content !== "string") return null;
      const parsed = JSON.parse(content);

      // Validate shape — reject anything not matching.
      if (
        typeof parsed.shouldHandoff !== "boolean" ||
        !Array.isArray(parsed.reasons) ||
        typeof parsed.suggestedActionType !== "string" ||
        !["low", "medium", "high"].includes(parsed.confidence)
      ) {
        return null;
      }
      return parsed as JudgeOutput;
    } finally {
      clearTimeout(timer);
    }
  };
}
```

- [ ] **Step 4: Add a unit test for the OpenRouter caller using a stubbed `fetchImpl`.**

Create `plugins/intercom/tests/judge.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { createOpenRouterJudge } from "../src/judge.js";

describe("createOpenRouterJudge", () => {
  it("parses a valid JSON response into JudgeOutput", async () => {
    const fetchImpl = (async () => ({
      ok: true,
      json: async () => ({
        choices: [
          {
            message: {
              content: JSON.stringify({
                shouldHandoff: true,
                reasons: ["frustration"],
                suggestedActionType: "support-general",
                confidence: "high",
              }),
            },
          },
        ],
      }),
    })) as unknown as typeof fetch;

    const judge = createOpenRouterJudge({
      openrouterApiKey: "k",
      model: "anthropic/claude-haiku-4-5-20251001",
      fetchImpl,
    });
    const out = await judge!({ knownFacts: {}, recentParts: [], currentMessage: "hi" });
    expect(out?.shouldHandoff).toBe(true);
    expect(out?.confidence).toBe("high");
  });

  it("returns null on malformed JSON", async () => {
    const fetchImpl = (async () => ({
      ok: true,
      json: async () => ({
        choices: [{ message: { content: "not json at all" } }],
      }),
    })) as unknown as typeof fetch;
    const judge = createOpenRouterJudge({
      openrouterApiKey: "k",
      model: "x",
      fetchImpl,
    });
    await expect(judge!({ knownFacts: {}, recentParts: [], currentMessage: "" })).rejects.toThrow();
  });

  it("returns null when shape doesn't match schema", async () => {
    const fetchImpl = (async () => ({
      ok: true,
      json: async () => ({
        choices: [{ message: { content: JSON.stringify({ shouldHandoff: "yes" }) } }],
      }),
    })) as unknown as typeof fetch;
    const judge = createOpenRouterJudge({
      openrouterApiKey: "k",
      model: "x",
      fetchImpl,
    });
    const out = await judge!({ knownFacts: {}, recentParts: [], currentMessage: "" });
    expect(out).toBeNull();
  });

  it("throws on non-2xx response (handler treats as fail-closed)", async () => {
    const fetchImpl = (async () => ({ ok: false, status: 503, json: async () => ({}) })) as unknown as typeof fetch;
    const judge = createOpenRouterJudge({
      openrouterApiKey: "k",
      model: "x",
      fetchImpl,
    });
    await expect(judge!({ knownFacts: {}, recentParts: [], currentMessage: "" })).rejects.toThrow(/503/);
  });
});
```

- [ ] **Step 5: Run, confirm all 4 judge tests pass.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/judge.test.ts`
Expected: 4 tests pass.

- [ ] **Step 6: Commit.**

```bash
git add plugins/intercom/src/judge.ts plugins/intercom/tests/judge.test.ts plugins/intercom/tests/escalation.test.ts
git commit -m "feat(intercom): LLM-judge layer for risk assessment (OpenRouter + Haiku)"
```

---

## Task 6: Create `escalation-action.ts` — handoff orchestrator

Composes the existing `outbound.ts` Intercom client + `slack.ts` payload builder + a new ClickUp ticket caller (HTTP) to file a real ticket. Order-of-operations matters; tested explicitly.

**Files:**
- Create: `plugins/intercom/src/escalation-action.ts`
- Create: `plugins/intercom/tests/escalation-action.test.ts`

- [ ] **Step 1: Write failing tests for the orchestrator.**

Create `plugins/intercom/tests/escalation-action.test.ts`:

```ts
import { describe, it, expect, vi } from "vitest";
import { executeEscalation } from "../src/escalation-action.js";
import type { IntercomSessionState, RiskAssessment, IntercomAccountConfig } from "../src/types.js";

function makeState(): IntercomSessionState {
  return {
    conversationId: "conv1",
    workspaceId: "ws1",
    handoffMode: "agent_active",
    lifecycleState: "open",
    currentAssigneeId: "bot",
    currentAssigneeType: "bot",
    lastEventId: null,
    processedEventIds: [],
    outboundMessageIds: [],
    createdAt: "",
    updatedAt: "",
    userTurnCount: 5,
    escalationFiredAt: null,
    knownFacts: { accountEmail: "jami@jamigrooms.com" },
  };
}

const account = {
  enabled: true,
  workspaceId: "ws1",
  token: "t",
  webhookSecret: "s",
  botAdminId: "bot",
  defaultInboxId: "5465657",
  fallbackSlackSupervisionChannel: "https://hooks.slack.example",
  fallbackAcknowledgement: "We'll get back to you.",
  requireMappedHumanAdmin: true,
  adminMapping: {},
} as IntercomAccountConfig;

const assessment: RiskAssessment = {
  triggered: true,
  source: "rule",
  reason: "refund_intent",
  matchedPattern: "\\brefund\\b",
  suggestedActionType: "subscription-refund",
  confidence: "high",
};

describe("executeEscalation", () => {
  it("sets dedupe gate BEFORE any I/O", async () => {
    const state = makeState();
    const order: string[] = [];
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      account,
      client: {
        replyToConversation: async () => { order.push("reply"); return { messageId: "m1" }; },
        assignConversation: async () => { order.push("assign"); },
        getConversation: async () => ({} as any),
      },
      saveState: async () => { order.push("save"); },
      createTicket: async () => { order.push("ticket"); return { ok: true, ticketId: "T1", sla: "5-10 business days" }; },
      postSlack: async () => { order.push("slack"); },
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });

    expect(state.escalationFiredAt).not.toBeNull();
    expect(state.handoffMode).toBe("human_takeover");
    expect(order[0]).toBe("save");           // gate persisted first
    expect(order[1]).toBe("ticket");         // ticket second
    expect(order.indexOf("reply")).toBe(2);  // farewell after ticket
  });

  it("uses the SLA-bearing farewell when ticket succeeds", async () => {
    const state = makeState();
    let farewellBody = "";
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      account,
      client: {
        replyToConversation: async (p) => { farewellBody = p.body; return { messageId: "m1" }; },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "5-10 business days" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    expect(farewellBody).toContain("5-10 business days");
    expect(farewellBody).toContain("T1");
    expect(farewellBody).toContain("jami@jamigrooms.com");
  });

  it("uses the degraded farewell when ticket fails", async () => {
    const state = makeState();
    let farewellBody = "";
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      account,
      client: {
        replyToConversation: async (p) => { farewellBody = p.body; return { messageId: "m1" }; },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: false, error: "ClickUp 503" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    expect(farewellBody).not.toContain("Reference");
    expect(farewellBody).toContain("shortly");
  });

  it("prepends 'Got it — ' for magic-keyword path", async () => {
    const state = makeState();
    let farewellBody = "";
    await executeEscalation({
      state,
      conversationId: "conv1",
      assessment: { ...assessment, source: "user_request", reason: "user_requested_human" },
      account,
      client: {
        replyToConversation: async (p) => { farewellBody = p.body; return { messageId: "m1" }; },
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "48 hours" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    });
    expect(farewellBody.startsWith("Got it — ")).toBe(true);
  });

  it("tolerates assignment conflict (human already grabbed it)", async () => {
    const state = makeState();
    const { IntercomAssignmentConflictError } = await import("../src/outbound.js");
    await expect(executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      account,
      client: {
        replyToConversation: async () => ({ messageId: "m1" }),
        assignConversation: async () => { throw new IntercomAssignmentConflictError("conflict"); },
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "x" }),
      postSlack: async () => {},
      log: { info: () => {}, warn: () => {}, error: () => {} },
    })).resolves.not.toThrow();
  });

  it("continues if Slack ping fails (logs but does not throw)", async () => {
    const state = makeState();
    await expect(executeEscalation({
      state,
      conversationId: "conv1",
      assessment,
      account,
      client: {
        replyToConversation: async () => ({ messageId: "m1" }),
        assignConversation: async () => {},
        getConversation: async () => ({} as any),
      },
      saveState: async () => {},
      createTicket: async () => ({ ok: true, ticketId: "T1", sla: "x" }),
      postSlack: async () => { throw new Error("slack down"); },
      log: { info: () => {}, warn: () => {}, error: () => {} },
    })).resolves.not.toThrow();
  });
});
```

- [ ] **Step 2: Run, confirm fail.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/escalation-action.test.ts`
Expected: FAIL — module not found.

- [ ] **Step 3: Create the orchestrator.**

Create `plugins/intercom/src/escalation-action.ts`:

```ts
import type {
  IntercomSessionState,
  IntercomAccountConfig,
  IntercomClient,
  RiskAssessment,
} from "./types.js";
import { IntercomAssignmentConflictError } from "./outbound.js";

export interface TicketResult {
  ok: boolean;
  ticketId?: string;
  sla?: string;
  error?: string;
}

export interface CreateTicketParams {
  actionType: string;
  customerEmail: string;
  customerProfileId?: string;
  summary: string;
  conversationSummary: string;
}

export interface ExecuteEscalationDeps {
  state: IntercomSessionState;
  conversationId: string;
  assessment: RiskAssessment;
  account: IntercomAccountConfig;
  client: IntercomClient;
  saveState: () => Promise<void>;
  createTicket: (p: CreateTicketParams) => Promise<TicketResult>;
  postSlack: (payload: unknown) => Promise<void>;
  log: { info: (msg: string) => void; warn: (msg: string) => void; error: (msg: string) => void };
}

function buildFarewell(assessment: RiskAssessment, ticket: TicketResult, email: string): string {
  const isMagic = assessment.source === "user_request";
  const prefix = isMagic ? "Got it — " : "";
  if (ticket.ok && ticket.ticketId && ticket.sla) {
    return `${prefix}I'm pulling in a teammate to take this from here. They'll follow up at ${email} within ${ticket.sla}. Reference: ${ticket.ticketId}.`;
  }
  return `${prefix}I'm pulling in a teammate to take this from here. They'll follow up at ${email} shortly.`;
}

function buildSummary(assessment: RiskAssessment, currentMessage: string): string {
  const prefix =
    assessment.source === "user_request" ? "User explicitly requested a human." :
    assessment.source === "rule" ? `Rule fired: ${assessment.reason}.` :
    `Judge flagged: ${assessment.reason}.`;
  return `${prefix} Last user message: ${currentMessage.slice(0, 400)}`;
}

export async function executeEscalation(deps: ExecuteEscalationDeps): Promise<void> {
  const { state, conversationId, assessment, account, client, saveState, createTicket, postSlack, log } = deps;

  // Step 1 — set dedupe gate, persist before any I/O.
  state.escalationFiredAt = new Date().toISOString();
  state.handoffMode = "human_takeover";
  state.updatedAt = state.escalationFiredAt;
  await saveState();

  const email = state.knownFacts?.accountEmail ?? "your account email on file";

  // Step 2 — file ClickUp ticket.
  let ticket: TicketResult = { ok: false, error: "ticket creation skipped" };
  try {
    ticket = await createTicket({
      actionType: assessment.suggestedActionType ?? "support-general",
      customerEmail: state.knownFacts?.accountEmail ?? "unknown@unknown",
      customerProfileId: state.knownFacts?.musoProfileId,
      summary: assessment.reason ?? "support",
      conversationSummary: buildSummary(assessment, ""),
    });
    if (ticket.ok) {
      log.info(`[intercom:escalation] ticket created conv=${conversationId} id=${ticket.ticketId}`);
    } else {
      log.warn(`[intercom:escalation] ticket creation failed conv=${conversationId} err=${ticket.error}`);
    }
  } catch (err) {
    ticket = { ok: false, error: String(err) };
    log.warn(`[intercom:escalation] ticket creation threw conv=${conversationId} err=${err}`);
  }

  // Step 3 — post farewell.
  const body = buildFarewell(assessment, ticket, email);
  try {
    await client.replyToConversation({
      conversationId,
      adminId: account.botAdminId,
      body,
    });
  } catch (err) {
    log.error(`[intercom:escalation] farewell post failed conv=${conversationId}: ${err}`);
  }

  // Step 4 — reassign to default escalation target.
  try {
    await client.assignConversation({
      conversationId,
      adminId: account.botAdminId,
      assigneeId: account.defaultInboxId || "0",
    });
    log.info(`[intercom:escalation] reassigned conv=${conversationId} → ${account.defaultInboxId || "Unassigned"}`);
  } catch (err) {
    if (err instanceof IntercomAssignmentConflictError) {
      log.info(`[intercom:escalation] reassign conflict (human already on it) conv=${conversationId}`);
    } else {
      log.error(`[intercom:escalation] reassign failed conv=${conversationId}: ${err}`);
    }
  }

  // Step 5 — Slack ping. Build a minimal payload here; full payload built in channel.ts where we have the full conv.
  try {
    await postSlack({
      text: `:rotating_light: Escalated conv ${conversationId}`,
      attachments: [
        {
          fields: [
            { title: "Reason", value: `${assessment.source}/${assessment.reason}`, short: true },
            { title: "Confidence", value: assessment.confidence ?? "n/a", short: true },
            { title: "Ticket", value: ticket.ok ? `#${ticket.ticketId} (${ticket.sla})` : `creation failed: ${ticket.error}`, short: false },
            { title: "Customer", value: email, short: false },
          ],
        },
      ],
    });
  } catch (err) {
    log.error(`[intercom:escalation] Slack ping failed conv=${conversationId}: ${err}`);
  }
}
```

- [ ] **Step 4: Run new tests, confirm pass.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/escalation-action.test.ts`
Expected: 6 tests pass.

- [ ] **Step 5: Commit.**

```bash
git add plugins/intercom/src/escalation-action.ts plugins/intercom/tests/escalation-action.test.ts
git commit -m "feat(intercom): handoff orchestrator (dedupe + ticket + farewell + reassign + Slack)"
```

---

## Task 7: Wire `assessRisk` into `handler.ts` under feature flag

**Files:**
- Modify: `plugins/intercom/src/handler.ts`
- Modify: `plugins/intercom/tests/handler.test.ts` (extend)

- [ ] **Step 1: Write failing tests for the new handler behavior.**

Append to `plugins/intercom/tests/handler.test.ts` (append, do not replace existing tests):

```ts
import { describe, it, expect, vi } from "vitest";
import { handleWebhookEvent } from "../src/handler.js";
import type { IntercomSessionState, IntercomWebhookPayload } from "../src/types.js";

function makeUserPayload(body: string, eventId = "evt-" + Math.random()): IntercomWebhookPayload {
  return {
    type: "notification_event",
    app_id: "app",
    data: { type: "notification_event_data", item: { type: "conversation", id: "conv1", title: null, created_at: 0, updated_at: 0, open: true, state: "open", source: { body, author: { type: "user", id: "u1" } } } as any },
    topic: "conversation.user.replied",
    id: eventId,
    created_at: 0,
    delivery_status: "ok",
    delivery_attempts: 1,
  };
}

function makeState(): IntercomSessionState {
  return {
    conversationId: "conv1",
    workspaceId: "ws1",
    handoffMode: "agent_active",
    lifecycleState: "open",
    currentAssigneeId: null,
    currentAssigneeType: null,
    lastEventId: null,
    processedEventIds: [],
    outboundMessageIds: [],
    createdAt: "",
    updatedAt: "",
    userTurnCount: 0,
    escalationFiredAt: null,
    knownFacts: {},
  };
}

describe("handler — flag off (legacy escalation path)", () => {
  it("uses legacy checkEscalation when riskAssessment is disabled", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayload("i want a refund"),  // not in legacy rules
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: false } },
    );
    expect(result.action).toBe("dispatch_to_agent");  // legacy regex misses 'refund'
  });
});

describe("handler — flag on (assessRisk path)", () => {
  it("dispatches to agent for benign messages", async () => {
    const state = makeState();
    const { result, state: out } = await handleWebhookEvent(
      makeUserPayload("hi"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(result.action).toBe("dispatch_to_agent");
    expect(out!.userTurnCount).toBe(1);  // turn count incremented
  });

  it("returns escalate action when refund intent fires", async () => {
    const state = makeState();
    const { result } = await handleWebhookEvent(
      makeUserPayload("i want a refund"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(result.action).toBe("escalate");
    if (result.action === "escalate") {
      expect(result.reason).toBe("refund_intent");
    }
  });

  it("short-circuits subsequent customer turns once escalationFiredAt is set", async () => {
    const state = makeState();
    state.escalationFiredAt = "2026-05-04T00:00:00Z";
    state.handoffMode = "human_takeover";
    const { result } = await handleWebhookEvent(
      makeUserPayload("any reply"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(result.action).toBe("filtered");
  });

  it("magic keyword bypasses escalationFiredAt (user re-requests human)", async () => {
    // Spec note: magic keyword bypasses dedupe — explicit consent always wins.
    const state = makeState();
    state.escalationFiredAt = "2026-05-04T00:00:00Z";
    state.handoffMode = "human_takeover";
    const { result } = await handleWebhookEvent(
      makeUserPayload("can i talk to a human"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(result.action).toBe("escalate");
  });

  it("pinned-fact extractor runs and updates knownFacts", async () => {
    const state = makeState();
    const { state: out } = await handleWebhookEvent(
      makeUserPayload("you can email me at me@example.com"),
      state,
      "bot",
      undefined,
      { riskAssessment: { enabled: true } },
    );
    expect(out!.knownFacts?.accountEmail).toBe("me@example.com");
  });
});
```

- [ ] **Step 2: Run, confirm fail.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/handler.test.ts -t "flag o"`
Expected: FAIL — `handleWebhookEvent` doesn't accept the 5th arg yet, and the new fields aren't wired.

- [ ] **Step 3: Extend `handler.ts` to accept config + dispatch the new path.**

In `plugins/intercom/src/handler.ts`, modify the imports and the function signature:

```ts
import type {
  IntercomWebhookPayload,
  IntercomSessionState,
  IntercomClient,
  RiskAssessment,
} from "./types.js";
import { RateLimitError } from "./outbound.js";
import { classifyEvent, createEventIdSet, isEventProcessed, trackEventId, isSelfReply } from "./filters.js";
import { checkEscalation, assessRisk, type AssessRiskDeps } from "./escalation.js";
import { updateKnownFacts } from "./extractors.js";
import {
  handleAssignment,
  handleAdminReply,
  handleLifecycleChange,
  handleImplicitReopen,
  canAgentReply,
} from "./handoff.js";

const apiShapeWarned = new Set<string>();

export type HandlerAction =
  | { action: "dispatch_to_agent"; conversationId: string; body: string; authorId: string }
  | { action: "escalate"; conversationId: string; assessment: RiskAssessment; body: string }
  // legacy (kept for backward-compat while flag is off):
  | { action: "escalate_legacy"; conversationId: string; category: string; matchedPattern: string; body: string }
  | { action: "state_updated"; conversationId: string; description: string }
  | { action: "filtered"; conversationId: string; reason: string }
  | { action: "ignored"; reason: string }
  | { action: "duplicate"; eventId: string }
  | { action: "invalid_signature" };

export interface HandlerOptions {
  riskAssessment?: { enabled: boolean };
  riskDeps?: AssessRiskDeps;     // judge etc.
  recentParts?: { author: "user" | "bot"; body: string }[];
}

export async function handleWebhookEvent(
  payload: IntercomWebhookPayload,
  state: IntercomSessionState | null,
  botAdminId: string,
  client?: IntercomClient,
  options?: HandlerOptions,
): Promise<{ result: HandlerAction; state: IntercomSessionState | null }> {
  // ... existing payload validation, idempotency, classification (unchanged) ...
```

Then locate the `case "customer_message":` block in `handleWebhookEvent` (around line 50) and modify it. Replace the existing escalation/dispatch logic — the part starting `// Check escalation before dispatching` through `return { result: { action: "dispatch_to_agent", ... }, state };` — with:

```ts
      // Update pinned facts from the customer message.
      if (state) {
        state.knownFacts = updateKnownFacts(classified.body, state.knownFacts ?? {});
        // Increment user-turn count (only on customer messages, not admin/bot/lifecycle).
        state.userTurnCount = (state.userTurnCount ?? 0) + 1;
        state.updatedAt = new Date().toISOString();
      }

      // Risk assessment — new path under flag, legacy under flag-off.
      const flagOn = options?.riskAssessment?.enabled === true;

      if (flagOn) {
        // Magic-keyword path bypasses escalationFiredAt; everything else respects it.
        const assessment = await assessRisk(
          classified.body,
          options?.recentParts ?? [],
          state ?? ({ userTurnCount: 0 } as IntercomSessionState),
          options?.riskDeps ?? {},
        );

        const isMagic = assessment.source === "user_request";
        const alreadyFired = !!state?.escalationFiredAt;

        if (assessment.triggered && (isMagic || !alreadyFired)) {
          if (state) {
            // Note: caller (channel.ts) is responsible for the actual handoff I/O via executeEscalation.
            // We just classify and return.
            state.handoffMode = "human_takeover";
            state.updatedAt = new Date().toISOString();
          }
          return {
            result: {
              action: "escalate",
              conversationId: classified.conversationId,
              assessment,
              body: classified.body,
            },
            state,
          };
        }
      } else {
        // Legacy path — preserved exactly until rollout step 6.
        const escalation = checkEscalation(classified.body);
        if (escalation.triggered) {
          if (state) {
            state.handoffMode = "human_takeover";
            state.updatedAt = new Date().toISOString();
          }
          return {
            result: {
              action: "escalate_legacy",
              conversationId: classified.conversationId,
              category: escalation.category!,
              matchedPattern: escalation.matchedPattern!,
              body: classified.body,
            },
            state,
          };
        }
      }

      // Suppress dispatch if agent cannot reply (human_takeover, snoozed, closed)
      if (state && !canAgentReply(state)) {
        return {
          result: {
            action: "filtered",
            conversationId: classified.conversationId,
            reason: `suppressed: ${state.handoffMode}/${state.lifecycleState}`,
          },
          state,
        };
      }

      return {
        result: {
          action: "dispatch_to_agent",
          conversationId: classified.conversationId,
          body: classified.body,
          authorId: classified.authorId,
        },
        state,
      };
```

- [ ] **Step 4: Run new tests + full handler test file.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/handler.test.ts`
Expected: all tests pass (existing + 5 new). The legacy `escalate` action in the existing tests now reads as `escalate_legacy` — update existing test expectations if any reference the old field shape.

- [ ] **Step 5: Fix any existing handler tests that assert on `result.action === "escalate"`.**

The legacy action is renamed to `escalate_legacy`. Search for old expectations:

Run: `cd plugins/intercom && grep -n 'escalate' tests/handler.test.ts | head -20`

Update each existing expectation that tested the legacy path. Old shape: `result.action === "escalate"` → new: `result.action === "escalate_legacy"`. The existing tests deliberately test legacy with `flagOn=false` (default), so renaming is the only change.

- [ ] **Step 6: Re-run, confirm green.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/handler.test.ts`
Expected: all tests pass.

- [ ] **Step 7: Commit.**

```bash
git add plugins/intercom/src/handler.ts plugins/intercom/tests/handler.test.ts
git commit -m "feat(intercom): wire assessRisk into handler under riskAssessment.enabled flag

Legacy 'escalate' action renamed 'escalate_legacy' for the rollout window;
the new flagged path returns 'escalate' with full RiskAssessment. After
rollout step 6 the legacy path + rename can be removed."
```

---

## Task 8: Wire `executeEscalation` into `channel.ts` + replace inline escalation block

**Files:**
- Modify: `plugins/intercom/src/channel.ts`

The existing inline escalation block at `channel.ts:329-405` handles `result.action === "escalate"` (legacy). Now that handler returns `escalate_legacy` for the legacy path and `escalate` for the new path, the existing block needs to handle BOTH during rollout: switch on action type, run new orchestrator for new action, keep inline ack→reassign→Slack for legacy.

- [ ] **Step 1: Construct the `createTicket` callback in channel.ts startup.**

Inside `gateway.startAccount` (after `account = resolveIntercomAccount(...)`), add right before the `tag = ...` line:

```ts
        // Build the ClickUp ticket caller — closures over creds. Returns ok=false if
        // creds aren't configured (handoff still proceeds with degraded farewell).
        const createTicket = account.clickup
          ? async (p: import("./escalation-action.js").CreateTicketParams) => {
              try {
                const tier =
                  p.actionType === "subscription-refund" || p.actionType === "dispute" ? 3 :
                  p.actionType === "profile-merge" || p.actionType === "bulk-credit-change" || p.actionType === "profile-update" ? 2 :
                  1;
                const sla = tier === 3 ? "5-10 business days" : tier === 2 ? "5 business days" : "48 hours";
                const customFields: { id: string; value: string }[] = [
                  { id: account.clickup!.userEmailFieldId, value: p.customerEmail },
                ];
                if (p.customerProfileId) {
                  customFields.push({ id: account.clickup!.profileIdFieldId, value: p.customerProfileId });
                }
                const res = await fetch(
                  `https://api.clickup.com/api/v2/list/${account.clickup!.listId}/task`,
                  {
                    method: "POST",
                    headers: {
                      "Content-Type": "application/json",
                      Authorization: account.clickup!.apiKey,
                    },
                    body: JSON.stringify({
                      name: `Intercom escalation: ${p.actionType}`,
                      description: `${p.summary}\n\n${p.conversationSummary}`,
                      status: "to do",
                      priority: tier === 3 ? 1 : tier === 2 ? 2 : 3,
                      tags: ["hydra-action-request", `tier-${tier}`, "intercom-auto-handoff"],
                      custom_fields: customFields,
                    }),
                  },
                );
                if (!res.ok) {
                  return { ok: false as const, error: `ClickUp ${res.status}` };
                }
                const data = (await res.json()) as { id: string };
                return { ok: true as const, ticketId: data.id, sla };
              } catch (err) {
                return { ok: false as const, error: String(err) };
              }
            }
          : async () => ({ ok: false as const, error: "ClickUp not configured" });
```

- [ ] **Step 2: Replace the existing `else if (result.action === "escalate")` block (lines 329-405) with a switch over both action types.**

Locate the block in `channel.ts` starting `} else if (result.action === "escalate") {` and ending at the matching `}`. Replace with:

```ts
                  } else if (result.action === "escalate") {
                    // New hybrid risk path — full ticket-bearing handoff.
                    const { executeEscalation } = await import("./escalation-action.js");
                    await executeEscalation({
                      state,
                      conversationId: result.conversationId,
                      assessment: result.assessment,
                      account,
                      client,
                      saveState: async () => { await saveSessions(accountSessions); },
                      createTicket,
                      postSlack: account.fallbackSlackSupervisionChannel
                        ? async (payload) => {
                            await fetch(account.fallbackSlackSupervisionChannel, {
                              method: "POST",
                              headers: { "Content-Type": "application/json" },
                              body: JSON.stringify(payload),
                            });
                          }
                        : async () => {},
                      log: {
                        info: (m) => log?.info?.(m),
                        warn: (m) => log?.warn?.(m),
                        error: (m) => log?.error?.(m),
                      },
                    });
                    log?.warn?.(
                      `[${tag}] ESCALATED conv=${result.conversationId} ` +
                      `source=${result.assessment.source} reason=${result.assessment.reason}`,
                    );
                  } else if (result.action === "escalate_legacy") {
                    // Legacy path — preserved for the rollout window. Delete after step 6.
                    try {
                      await client.replyToConversation({
                        conversationId: result.conversationId,
                        adminId: account.botAdminId,
                        body: account.fallbackAcknowledgement,
                      });
                    } catch (err) {
                      log?.error?.(`[${tag}] escalation ack failed conv=${result.conversationId}: ${err}`);
                    }
                    try {
                      await client.assignConversation({
                        conversationId: result.conversationId,
                        adminId: account.botAdminId,
                        assigneeId: account.defaultInboxId || "0",
                      });
                      log?.info?.(`[${tag}] reassigned conv=${result.conversationId} to ${account.defaultInboxId || "Unassigned"}`);
                    } catch (err) {
                      log?.error?.(`[${tag}] reassignment failed conv=${result.conversationId}: ${err}`);
                    }
                    if (account.fallbackSlackSupervisionChannel) {
                      const escalationSummary = {
                        conversationId: result.conversationId,
                        category: result.category,
                        matchedPattern: result.matchedPattern,
                        body: result.body,
                      };
                      let slackPayload;
                      try {
                        const conversation = await client.getConversation({ conversationId: result.conversationId });
                        slackPayload = buildEscalationSlackMessage(escalationSummary, conversation, account, state);
                      } catch (err) {
                        log?.warn?.(`[${tag}] Slack enrichment fetch failed conv=${result.conversationId}: ${err} — posting minimal`);
                        slackPayload = buildEscalationSlackMessageMinimal(escalationSummary, account);
                      }
                      try {
                        await fetch(account.fallbackSlackSupervisionChannel, {
                          method: "POST",
                          headers: { "Content-Type": "application/json" },
                          body: JSON.stringify(slackPayload),
                        });
                      } catch (err) {
                        log?.error?.(`[${tag}] Slack escalation notification failed: ${err}`);
                      }
                    }
                    log?.warn?.(
                      `[${tag}] ESCALATED (legacy) conv=${result.conversationId} ` +
                      `category=${result.category} pattern=${result.matchedPattern}`,
                    );
                  }
```

- [ ] **Step 3: Pass options into the handler call. Modify line 211** (the `handleWebhookEvent` call):

```ts
                  // Build risk-assessment deps + options once per webhook.
                  const riskOptions = account.riskAssessment?.enabled
                    ? {
                        riskAssessment: { enabled: true },
                        riskDeps: {
                          judgeMinTurnCount: account.riskAssessment.judgeMinTurnCount ?? 4,
                          turnCountHardCap: account.riskAssessment.turnCountHardCap ?? 6,
                          // judge wired in later when we have an OpenRouter key in cfg
                        },
                      }
                    : { riskAssessment: { enabled: false } };
                  const { result } = await handleWebhookEvent(
                    payload,
                    state,
                    account.botAdminId,
                    client,
                    riskOptions,
                  );
```

- [ ] **Step 4: Run channel.test.ts.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/channel.test.ts`
Expected: existing tests pass. (We'll add the `[CONVERSATION_CONTEXT]` injection test in Task 9.)

- [ ] **Step 5: Run the full plugin test suite.**

Run: `cd plugins/intercom && pnpm exec vitest run`
Expected: all tests green. Any failures = fix before commit.

- [ ] **Step 6: Commit.**

```bash
git add plugins/intercom/src/channel.ts
git commit -m "feat(intercom): wire executeEscalation into channel.ts + retain legacy path under flag"
```

---

## Task 9: Inject `[CONVERSATION_CONTEXT]` into `rawBody` + outbound sanitization

This is the spec's "fact injection mechanism — option 1" (inline-prepend with regurgitation guard).

**Files:**
- Modify: `plugins/intercom/src/channel.ts`
- Modify: `plugins/intercom/tests/channel.test.ts` (extend)

- [ ] **Step 1: Write failing test for the prepend.**

Append to `plugins/intercom/tests/channel.test.ts`:

```ts
import { describe, it, expect } from "vitest";
import { buildAgentRawBody, stripConversationContext } from "../src/channel.js";

describe("buildAgentRawBody", () => {
  it("returns customer message unchanged when there are no known facts", () => {
    expect(buildAgentRawBody("hello", {})).toBe("hello");
  });

  it("prepends a CONVERSATION_CONTEXT block when facts exist", () => {
    const out = buildAgentRawBody("hi", { accountEmail: "x@y.com", planTier: "Pro" });
    expect(out).toContain("[CONVERSATION_CONTEXT]");
    expect(out).toContain("account email: x@y.com");
    expect(out).toContain("plan tier: Pro");
    expect(out).toContain("[CUSTOMER_MESSAGE]\nhi");
  });

  it("omits unset fields", () => {
    const out = buildAgentRawBody("hi", { accountEmail: "x@y.com" });
    expect(out).not.toContain("plan tier");
    expect(out).not.toContain("primary complaint");
  });
});

describe("stripConversationContext", () => {
  it("removes a [CONVERSATION_CONTEXT] block if the model regurgitates it", () => {
    const input = "[CONVERSATION_CONTEXT]\naccount email: x@y.com\n[/CONVERSATION_CONTEXT]\nThanks for letting me know.";
    expect(stripConversationContext(input)).toBe("Thanks for letting me know.");
  });

  it("removes a stray '[CONVERSATION_CONTEXT]' opening line on its own", () => {
    const input = "[CONVERSATION_CONTEXT]\nThanks for asking.";
    expect(stripConversationContext(input)).toBe("Thanks for asking.");
  });

  it("returns unchanged text when no marker is present", () => {
    expect(stripConversationContext("hello")).toBe("hello");
  });
});
```

- [ ] **Step 2: Run, confirm fail (functions don't exist).**

Run: `cd plugins/intercom && pnpm exec vitest run tests/channel.test.ts -t "buildAgentRawBody\\|stripConversationContext"`
Expected: FAIL — exports not found.

- [ ] **Step 3: Add the two helpers to `channel.ts` (above `intercomPlugin`).**

```ts
import type { KnownFacts } from "./types.js";

/**
 * Render KnownFacts as a [CONVERSATION_CONTEXT] block prepended to the
 * customer message. Empty knownFacts produces no block (no noise on first
 * contact). The agent's SOUL.md instructs it to treat this block as
 * authoritative ground truth and never echo it.
 */
export function buildAgentRawBody(message: string, facts: KnownFacts): string {
  const lines: string[] = [];
  if (facts.accountEmail) lines.push(`- account email: ${facts.accountEmail}`);
  if (facts.musoProfileUrl) lines.push(`- muso profile: ${facts.musoProfileUrl}`);
  if (facts.planTier) lines.push(`- plan tier: ${facts.planTier}`);
  if (facts.primaryComplaint) lines.push(`- primary complaint: ${facts.primaryComplaint}`);
  if (lines.length === 0) return message;
  return [
    "[CONVERSATION_CONTEXT]",
    "Known about this user (do not re-ask):",
    ...lines,
    "[/CONVERSATION_CONTEXT]",
    "[CUSTOMER_MESSAGE]",
    message,
  ].join("\n");
}

/**
 * Outbound regurgitation guard — strips any [CONVERSATION_CONTEXT] block (and
 * stray opening tag) from agent replies before they hit Intercom. SOUL.md
 * tells the agent not to echo, but cheap insurance.
 */
const CONTEXT_BLOCK_REGEX = /\[CONVERSATION_CONTEXT\][\s\S]*?\[\/CONVERSATION_CONTEXT\]\s*/g;
const CONTEXT_OPEN_LINE_REGEX = /^\[CONVERSATION_CONTEXT\][^\n]*\n?/gm;

export function stripConversationContext(reply: string): string {
  if (!reply.includes("[CONVERSATION_CONTEXT]")) return reply;
  return reply.replace(CONTEXT_BLOCK_REGEX, "").replace(CONTEXT_OPEN_LINE_REGEX, "").trim();
}
```

- [ ] **Step 4: Wire `buildAgentRawBody` into the dispatch call.**

Locate `rawBody: result.body,` in `channel.ts` (inside `dispatchInboundDirectDmWithRuntime`). Replace with:

```ts
                      rawBody: buildAgentRawBody(result.body, state.knownFacts ?? {}),
```

- [ ] **Step 5: Wire `stripConversationContext` into the outbound path.**

Locate the `replyToConversation` call in the buffered-flush block (line ~306). Modify:

```ts
                        const { messageId } = await client.replyToConversation({
                          conversationId: result.conversationId,
                          adminId: account.botAdminId,
                          body: stripConversationContext(joined),
                        });
```

Also wire it into the `outbound.attachedResults.sendText` call near line 461:

```ts
        const { messageId } = await client.replyToConversation({
          conversationId,
          adminId: account.botAdminId,
          body: stripConversationContext(text),
        });
```

- [ ] **Step 6: Run channel tests.**

Run: `cd plugins/intercom && pnpm exec vitest run tests/channel.test.ts`
Expected: all tests pass.

- [ ] **Step 7: Commit.**

```bash
git add plugins/intercom/src/channel.ts plugins/intercom/tests/channel.test.ts
git commit -m "feat(intercom): inject [CONVERSATION_CONTEXT] + outbound regurgitation guard"
```

---

## Task 10: Add SOUL.md honesty rules + CONVERSATION_CONTEXT directive

**Files:**
- Modify: `workspaces/support/SOUL.md`

- [ ] **Step 1: Read current SOUL.md to find a good insertion point.**

Run: `wc -l workspaces/support/SOUL.md && head -40 workspaces/support/SOUL.md`

Look for an existing "Rules" or "Behavior" section; the new sections go just after it. If none, append at end.

- [ ] **Step 2: Append the new sections to `workspaces/support/SOUL.md`.**

Add at end of file:

```markdown

## Conversation context (authoritative)

When you receive a customer message, you may see a `[CONVERSATION_CONTEXT]` block before the actual message. Example:

```
[CONVERSATION_CONTEXT]
Known about this user (do not re-ask):
- account email: jami@jamigrooms.com
- plan tier: Pro
[/CONVERSATION_CONTEXT]
[CUSTOMER_MESSAGE]
i'm still having issues
```

Rules:
- Treat the `[CONVERSATION_CONTEXT]` block as authoritative ground truth — DO NOT ask the user for any fact already listed there.
- DO NOT echo, quote, or mention the `[CONVERSATION_CONTEXT]` block in your reply. The user does not see it; treating it as part of the message would confuse them.
- Reply only to the content under `[CUSTOMER_MESSAGE]`.

## Honesty rules (no fabrication)

- NEVER claim a ticket was created unless you actually called `create_ticket` in this turn AND received a successful response. If you would otherwise say "I've created a ticket" without a real tool call, say "I'll flag this for our team" instead.
- NEVER invent SLA timeframes ("you'll hear back within 1 business day", "5 business days", "senior support reviews within X"). When reporting back to the user about a ticket, use the literal SLA returned by `create_ticket` — do not paraphrase, shorten, or guess.
- NEVER invent ticket IDs, reference numbers, or case numbers.
- If `create_ticket` is not available as a tool in this turn, do not promise human follow-up at all. Say "I'd recommend emailing support@muso.ai with details" and stop.
```

- [ ] **Step 3: Pre-commit guard sanity check.**

Run: `git diff workspaces/support/SOUL.md | grep -iE 'claude-|gpt-|haiku|sonnet|opus|fireworks|kimi-|glm-|deepseek'`
Expected: no output. (The pre-commit hook for issue #117 blocks hardcoded model names in workspace SOUL.md.)

- [ ] **Step 4: Commit.**

```bash
git add workspaces/support/SOUL.md
git commit -m "feat(support-agent): SOUL.md honesty rules + CONVERSATION_CONTEXT directive"
```

---

## Task 11: Enable `support-tools` plugin on main profile + populate config

**Files:**
- Modify: `openclaw-main.json`

- [ ] **Step 1: Read current `plugins.entries` in `openclaw-main.json`.**

Run: `jq '.plugins.entries' openclaw-main.json`
Expected: shows the existing 6 entries (slack, openclaw-gmail, intercom, muso-credit-verification-enforcer, openrouter, browser).

- [ ] **Step 2: Add `support-tools` entry.**

Edit `openclaw-main.json` — under `plugins.entries`, add:

```json
"support-tools": { "enabled": true },
```

- [ ] **Step 3: Add `create_ticket` to the support agent's tool allowlist.**

Run: `jq '.agents | keys' openclaw-main.json` to confirm the support agent key (likely `support`).

Then locate the support agent's `tools` array and add `"create_ticket"`. Use a manual edit; example diff target:

```json
  "agents": {
    "support": {
      "tools": [
        "...existing tools...",
        "create_ticket"
      ],
```

- [ ] **Step 4: Add the intercom plugin's `clickup` config + `riskAssessment` block.**

Locate `channels.intercom.accounts.default` and add:

```json
"riskAssessment": {
  "enabled": false,
  "judgeModel": "anthropic/claude-haiku-4-5-20251001",
  "judgeMinTurnCount": 4,
  "turnCountHardCap": 6
},
"clickup": {
  "apiKey": "$$secret:CLICKUP_API_KEY$$",
  "listId": "$$secret:CLICKUP_LIST_ID$$",
  "userEmailFieldId": "$$secret:CLICKUP_USER_EMAIL_FIELD_ID$$",
  "profileIdFieldId": "$$secret:CLICKUP_PROFILE_ID_FIELD_ID$$"
}
```

(The `$$secret:...$$` substitution syntax follows the existing convention in this file — check existing usages in the file before committing the exact form.)

- [ ] **Step 5: Provision secrets in `secrets/`.**

Per `project_support_tools_deploy.md` memory note, the ClickUp `Profile ID` custom field needs creating in ClickUp UI before this can be populated.

Manual prerequisites (cannot be automated):
1. In ClickUp UI: Settings → custom fields → create `Profile ID` text field on the support list. Capture its field ID from the URL or API.
2. Add the four ClickUp values to the `secrets/` SOPS-encrypted store (consult existing convention by `cat secrets/README.md` or `ls secrets/`).
3. Confirm via SSH on hydra that the secrets resolve at runtime: `ssh -i ~/.ssh/nick_ovh root@40.160.32.80 'jq .channels.intercom.accounts.default.clickup /root/.openclaw-main/openclaw.json'`

These are P0 — without them, ticket creation will fail and farewells will use the degraded text. The plugin is designed to ship in this degraded state without breaking, but success criteria can't be met until these land.

- [ ] **Step 6: Commit.**

```bash
git add openclaw-main.json
git commit -m "config(main): enable support-tools plugin + intercom clickup/riskAssessment blocks

Flag riskAssessment.enabled stays FALSE in this commit — explicit toggle
to true is part of the rollout plan, not the merge."
```

---

## Task 12: Final integration smoke + open PR

- [ ] **Step 1: Run the full plugin test suite to confirm no regressions.**

Run: `cd plugins/intercom && pnpm exec vitest run`
Expected: all tests pass.

- [ ] **Step 2: TypeScript check.**

Run: `cd plugins/intercom && pnpm exec tsc --noEmit`
Expected: zero errors.

- [ ] **Step 3: Push + open PR.**

```bash
git push -u origin design/intercom-bot-self-protection
gh pr create --title "feat(intercom): bot self-protection (post-Jami)" --body "$(cat <<'EOF'
## Summary
- Hybrid risk detection (broadened rules + LLM-judge backstop) replaces narrow regex
- Magic-keyword "talk to a human" affordance — Layer 0
- Pinned-fact session memory (email + Muso profile URL → injected into agent prompt as CONVERSATION_CONTEXT)
- Real ClickUp ticket creation on every handoff (replaces theatrical "I've created a ticket" promises)
- SOUL.md honesty rules forbidding ticket/SLA fabrication
- All gated by `riskAssessment.enabled` flag (default OFF for backward-compat)

Spec: `docs/2026-05-04-intercom-bot-self-protection-design.md`
Plan: `docs/superpowers/plans/2026-05-04-intercom-bot-self-protection.md`
Triggered by: conv 215474098923209 (Jami) — bot replied 30+ times without handoff and fabricated 3 ticket promises.

## Test plan
- [x] Unit tests: extractors (6), assessRisk Layers 0-1 (11), Layer 2 wiring (5), judge OpenRouter caller (4), escalation-action (6), handler new behavior (5), channel context injection (6)
- [x] Type check passes
- [ ] Manual on edge profile: replay sanitized Jami transcript, verify handoff fires by turn 4-5, real ticket created, Slack ping lands
- [ ] Manual: send "talk to a human" → handoff fires immediately
- [ ] Manual: send "my email is foo@bar.com" → second turn does not get re-asked for email
- [ ] After secrets + ClickUp custom field provisioned, flip flag on edge for 24h, watch metrics
- [ ] Flip on main profile, Aaron + Jan eyeball 5-10 live conversations
EOF
)"
```

- [ ] **Step 4: After PR opens, manual smoke on edge profile (post-merge).**

Manual steps for the deployer (not automated — runs after PR merges and deploy lands):

1. Provision the four ClickUp secrets + Profile ID custom field (Task 11 step 5).
2. SSH to hydra: `ssh -i ~/.ssh/nick_ovh root@40.160.32.80`
3. Verify support-tools plugin mirrored to main: `ls /root/.openclaw-main/extensions/ | grep support-tools`
4. Edit `/root/.openclaw-edge/openclaw.json` to set `channels.intercom.accounts.default.riskAssessment.enabled = true` for edge profile only.
5. Restart edge gateway: `systemctl restart openclaw-gateway-edge`
6. Send a test conversation in Intercom that includes "i want a refund" — confirm:
   - bot posts farewell with ticket reference
   - ClickUp shows new task with `hydra-action-request` + `tier-3` tags
   - Slack supervision channel receives ping
7. Watch journalctl for errors: `journalctl -u openclaw-gateway-edge -f`
8. After ~24h with no surprises, repeat steps 4-7 for main profile.
9. After 1 week stable, schedule a follow-up PR to delete the legacy `checkEscalation()` and `escalate_legacy` action (rollout step 6).

---

## Self-review checklist

(Run mentally before marking the plan done.)

**Spec coverage:**
- ✅ Hybrid risk detection (rules + judge): Tasks 4–5
- ✅ Magic-keyword: Task 4 Layer 0
- ✅ Pinned-fact memory: Tasks 3 + 9
- ✅ Real ticket on every handoff: Tasks 6 + 8 + 11
- ✅ SOUL.md honesty rules: Task 10
- ✅ Deploy prerequisites (support-tools enable + creds): Task 11

**Type consistency check:**
- `RiskAssessment` shape introduced in Task 1, used identically in Tasks 4, 6, 7, 8 ✓
- `KnownFacts` shape introduced in Task 1, used identically in Tasks 3, 9 ✓
- `CreateTicketParams` / `TicketResult` introduced in Task 6, used identically in Task 8 ✓
- `escalate_legacy` action added in Task 7, handled in Task 8 ✓

**Placeholder scan:** none.

**Risks / known gotchas (called out in-task):**
- Pre-commit hook for SOUL.md model names: addressed in Task 10 step 3.
- `escalate_legacy` rename will break any existing handler test that asserts on `result.action === "escalate"`: addressed in Task 7 step 5.
- ClickUp custom-field creation is manual and a P0 deploy blocker: addressed in Task 11 step 5.
- The dispatch SDK has no per-conversation system-prompt slot — we use option 1 (inline-prepend) per spec. Task 9 implements + sanitizes.
