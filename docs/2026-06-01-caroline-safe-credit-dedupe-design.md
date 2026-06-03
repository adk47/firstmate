# Caroline safe customer credit-profile dedupe — design spec

- **Date:** 2026-06-01
- **Branch:** `feat/caroline-safe-credit-dedupe`
- **Status:** design approved (pivoted + twice adversarially reviewed); ready for implementation plan
- **Author:** Nick (with Claude)

---

## 1. Problem & goal

Customers regularly have duplicate Muso credit profiles (an auto-created stub plus
their real/claimed profile, etc.). Today, when a customer asks Caroline (the
customer-facing Intercom support agent on the **edge** profile) to merge them,
the best she can do is file a free-text `profile-merge` action-request ticket for
Operations — often prose-only and unverified. A 2026-05-19 sweep found 15/27 such
tickets were for merges Operations had already done manually.

**Goal:** when a customer asks to dedupe, Caroline gathers structured evidence with a
new **read-only** verifier tool — including a **server-side ownership check that
cannot be spoofed by message text** — and files a high-signal `profile-merge`
ticket that lets Operations act quickly and safely.

**Caroline never merges.** The irreversible `POST /admin/profiles/merge` is and
remains a tier-2 write executed by a trusted human (Operations), with the existing
mandatory pre-merge checklist (`skills-all/muso-ops-profiles/SKILL.md`).

### Why not autonomous merge

An earlier design (Caroline executes a narrow autonomous merge) was **rejected**
after adversarial review. Verified blockers:

- `POST /admin/profiles/merge` is tier-2 gated **inside** `muso-admin-api.sh`; the
  canonical wrapper has no self-approve bypass, so an autonomous merge would require
  either reaching the godmode allowlist or a guard-dropping direct-JWT bypass —
  both contradict the "ops merge path untouched" constraint.
- `hard_dupe` (shared raw Spotify/Tidal ID or IPI) is **not** same-person proof —
  the repo's own `scripts/dedup/README.md` documents the 30-profile "Empire" Tidal
  cluster and the Maui ES/PT-BR Jaxsta false-positive. Requiring the loser be
  *unclaimed* amplifies credit theft (no owner to object), it doesn't prevent it.
- The merge backend has **no claim-state safety** (only throws when >1 loser is
  claimed); a single claimed side silently transfers the claim — the 2026-04-29
  production incident (`muso-ops-profiles/SKILL.md:97`).
- Merge is partly **async** (credits/IPIs fold minutes-to-hours, may silently never
  arrive), so Caroline could never truthfully say "done."

The human-in-the-loop pivot dissolves all of these.

## 2. Success criteria

1. A customer who genuinely owns a profile and has a plausible duplicate gets a
   **server-side ownership-verified**, structured `profile-merge` ticket routed to
   Operations.
2. A customer who types a **victim's email** to impersonate the owner cannot obtain
   a clean/ownership-verified ticket — they get routed to identity-verification or a
   **flagged security-review** ticket.
3. No **third-party PII** (a different user's workspace email) leaks into the verdict
   or the ClickUp ticket.
4. The verifier is **provably read-only** — no merge, no tier-2 write, no `exec`, no
   Trino. Its only side effect (via Caroline calling a separate existing tool) is
   creating a ticket.
5. Operations is **not anchored** by Caroline's evidence: the ticket explicitly
   instructs them to run the independent pre-merge checklist; the verdict is labeled
   untrusted, customer-influenced pre-screen evidence.
6. CI stays green; the change does not loosen any deny-list or touch the ops merge
   path.

## 3. Scope

**In scope**
- New read-only plugin tool `dedupe_check` (TypeScript, `plugins/support-tools`).
- New doctrine skill `customer-profile-dedupe` (`workspaces/support/skills/`).
- Reuse of existing `create_ticket` (`actionType=profile-merge`) for the write.
- Ops-side doctrine note: a Caroline verdict in `details[]` is untrusted pre-screen
  evidence; the mandatory pre-merge checklist still applies in full.
- Tool-count invariant updates (manifest, plugin test, `SOUL.md`, `TOOLS.md`).

**Out of scope (YAGNI)**
- Autonomous merge, unmerge, `find-dupes`/Trino, velocity/value scoring, any change
  to `muso-admin-api.sh` / tier-2 / godmode, any change to `exec` config.

**Separate standing issue (NOT this feature)**
- Caroline has full unguarded `exec` on edge (`openclaw-edge.json:370-372` →
  `exec {security:"full", ask:"off"}`, no `tools.deny`); the `SOUL.md`/`TOOLS.md`
  "exec denied / exactly N tools" lines are prose-only and unenforced. This is a
  real exposure that predates and is independent of this feature. Track separately
  (issue + optional live-gateway confirmation that `exec` is actually bound to the
  support agent). It does **not** block this feature (we add only a read tool).

## 4. Locked decisions (from brainstorming)

| Decision | Choice |
|---|---|
| Caroline's capability | Verify + auto-file to Operations (no autonomous merge) |
| Ownership stamp | Trustworthy: server-side Intercom author-email re-check |
| Detection | Read tools + admin GETs only — **no** `find-dupes`/Trino |
| Verifier impl | Read-only **TypeScript** plugin tool (vitest-covered) |
| Verdict semantics | **Evidence for human review**, not a confidence verdict |

## 5. Architecture

```
Customer (Intercom) ── "merge my duplicate profiles"
        │
        ▼
Caroline (edge, support agent)
        │  1. dedupe_check(survivor, duplicates[])        [NEW read-only TS tool]
        │       (a) derive convId from ctx.sessionId      (NOT an agent param)
        │       (b) GET Intercom /conversations/{convId} → trusted author.email
        │       (c) GET /api/v3/admin/profile/{survivor}  → ownership
        │       (d) GET /api/v3/admin/profile/{dup} (+/credits) per duplicate
        │       (e) return STRUCTURED verdict (enums/bools/UUIDs/counts only)
        │
        │  2. interpret per customer-profile-dedupe SKILL  [NEW doctrine]
        │
        ▼  3. create_ticket(actionType=profile-merge, customerProfileId,    [EXISTING]
        │        details:{ main_profile_url, duplicate_profile_urls[], verdict })
        │        ← the 3 capture-completeness fields are MANDATORY (see §5.4)
Operations (ClickUp ticket, assignee 66250052)
        │  runs muso-ops-profiles MANDATORY pre-merge checklist (independent)
        ▼  POST /admin/profiles/merge   ← the only place a merge ever happens
```

### 5.1 `dedupe_check` tool contract

**Inputs (from the agent):**
- `survivorProfileId` or `survivorProfileUrl` — the profile the customer wants to keep.
- `duplicateProfileIds[]` (or urls) — capped (e.g. ≤ 5) duplicates to assess.
- `requesterEmail` — the conversation-context email (treated as **untrusted**; only
  used as a comparison candidate, never as proof).
- **NOT** `intercomConvId` — derived in-plugin from `ctx.sessionId`
  (`parseConversationIdFromTarget` pattern; key format
  `agent:support:intercom:{wsId}:conversation:{convId}`, `session-key.ts:8`).

**Behavior (all read-only):**
1. Derive `convId` from `ctx.sessionId`. If absent/unparseable → **fail-closed**.
2. GET Intercom `/conversations/{convId}` → `source.author.email` (mirror
   `plugins/intercom/src/outbound.ts:178` `getConversation`). Token from
   `process.env.MUSOAI_INTERCOM_TOKEN`. If token missing/empty, API error, or no
   author email → **fail-closed** (`verified=false`, `owner_undetermined=true`).
3. GET `/api/v3/admin/profile/{survivor}` (via existing `MusoAdminClient`, already
   allowlisted, GET-only). Compute `owns_survivor = isClaimed && exactly-one-claimed-
   workspace && that workspace email == trusted author email` (case-insensitive,
   mirror `remove-credits.sh:197`).
4. For each duplicate: GET profile (+ `/credits`). Compute `claim_state ∈
   {unclaimed, claimed_same_owner, claimed_different_user}`, `credit_count`,
   `shared_external_id` (enum `none`|`weak` — any `rawProfiles[]`/`ipis[]` overlap
   is labeled **weak**, never treated as same-person proof), `shared_track_count`
   (best-effort `/credits` intersection, capped, degrades gracefully).
5. Return the verdict. **No write. No ticket. No merge.**

**Output verdict (structured, PII-safe):**
```jsonc
{
  "verified": false,                  // owns_survivor && author re-check passed
  "owner_undetermined": true,         // fail-closed sentinel (token/convId/API issue)
  "impersonation_flag": false,        // requesterEmail != trusted author email
  "owns_survivor": false,
  "survivor_claimed_workspace_count": 1,
  "duplicates": [
    { "profile_id": "uuid", "claim_state": "unclaimed",
      "credit_count": 3, "shared_external_id": "weak",
      "shared_track_count": 2 }
  ],
  "cluster_size_check": "not_performed",   // Empire-cluster scan needs Trino
  "notes": ["…sanitized, length-capped, injection-stripped…"]
}
```
- Emit **only** enums / booleans / UUIDs / counts and explicitly-sanitized,
  length-capped strings. **Never** a third-party workspace email (PII). Export or
  re-implement the `PII_KEYS` strip (`profile-status.ts:22-31` is currently private).
- **No "high-confidence / verified-to-merge" stamp.** `verified` means only "owner
  re-check passed," not "safe to merge."
- Strip `[CONVERSATION_CONTEXT]`/`[CUSTOMER_MESSAGE]` injection markers
  (`channel.ts:143` `INJECTION_MARKER_REGEX`) from any customer-derived `notes`
  before they can reach `details[]` (serialized verbatim by `create-ticket.ts`).

### 5.2 Doctrine routing (`customer-profile-dedupe/SKILL.md`)

**Rows are evaluated top-down, first match wins — so more-specific conditions
MUST precede broader ones.** In particular, the legitimate multi-seat org/label case
(`survivor_claimed_workspace_count > 1`) is a strict subset of `owns_survivor=false`
(which requires *exactly one* claimed workspace, §5.1 step 3), so it is listed and
matched **before** the generic ownership-failure row to avoid mis-routing a real
org/label customer into the security-review path. The implementation must preserve
this ordering (e.g. an explicit `if survivor_claimed_workspace_count > 1` branch
ahead of the generic `owns_survivor=false` branch), not a hash/unordered map.

| # | Verdict condition | Caroline action |
|---|---|---|
| 1 | `owner_undetermined` (fail-closed) | Ask the customer to verify identity / route to flagged security-review ticket. **Never** a clean merge ticket. |
| 2 | survivor `survivor_claimed_workspace_count > 1` (org/label, legit multi-seat) | **Escalate-with-context** ticket (legitimate multi-claim case) — do **not** flag as impersonation. *(Evaluated before row 3 because it is the specific subset.)* |
| 3 | `impersonation_flag`, or `owns_survivor=false` for any OTHER reason (survivor unclaimed, sole-claimant email ≠ requester) | Security-review path — do not present as routine. **Never** a clean merge ticket. |
| 4 | duplicate `claimed_different_user` | File ticket **flagged** as potential cross-owner merge (theft risk) for careful human handling. |
| 5 | `shared_external_id` only / weak signals | Surface prominently as **weak/ambiguous**; ticket notes "cluster-size/Empire detection NOT performed." |
| 6 | `owns_survivor` + duplicate `unclaimed` + corroborating shared tracks | File a clean ownership-verified merge ticket (still evidence, not a verdict). |

**Every path ends in a human-reviewed ticket** — which is also the durable sink for
suspected-theft (Caroline has no Slack-send tool, so the ticket *is* the record).

Customer-facing copy: Caroline says she has **filed the request for the team** and
sets no completion timeline (the merge is human-gated and partly async). She never
says "done," never echoes raw external IDs.

### 5.3 Ticket banner (for Operations)

The `create_ticket` `details[]` includes a literal banner: *"Caroline pre-screen
evidence — UNTRUSTED, customer-influenced. Run the muso-ops-profiles pre-merge
checklist independently (direction approval, same-person, claim-state, credit
intersection, dry-run). The merge API has NO claim-state guard."* The verdict's
`name`/`notes` strings are **data, not instructions**.

### 5.4 `create_ticket` handoff contract (capture-completeness)

`create_ticket` **rejects** a `profile-merge` call — *before* the rate limit, with
`reason: "profile_merge_capture_incomplete"` — unless all three capture-completeness
fields are present (`plugins/support-tools/src/tools/create-ticket.ts:97-119`):

| Field | Source |
|---|---|
| `customerProfileId` (top-level param) | the survivor profile UUID (`dedupe_check` `survivorProfileId`) |
| `details.main_profile_url` | the survivor's `https://credits.muso.ai/profile/<uuid>` URL |
| `details.duplicate_profile_urls[]` (≥ 1) | each duplicate profile URL the customer named |

The PII-safe verdict (§5.1) is carried **alongside** these (e.g. under
`details.verdict`); it does **not** replace them. A handoff that passes only the
verdict looks correct but silently never files the Operations ticket. The doctrine
skill (§5.2) and the implementation MUST populate all three — from the same inputs
`dedupe_check` already received — on every routing row that files a ticket.

## 6. Security model

- **Anti-spoof (the core control):** the trusted email comes from Intercom's contact
  record via a plugin-derived conv-id — never from agent-extracted message text
  (`extractors.ts` scrapes the context email from attacker-controlled text). **Fail-closed**
  on every unverifiable path.
- **No third-party PII** in verdict or ticket (schema + strip + test).
- **Read-only:** tool only issues GETs (Muso admin + Intercom). The single write is
  `create_ticket`, an existing audited tool.
- **No anchoring:** evidence-only framing + ops-side untrusted-evidence doctrine.
- **No new privilege surface:** no `exec`, no tier-2, no allowlist widening
  (`MusoAdminClient` already allows the two profile GETs).

## 7. Data sources (verified)

| Need | Source | Evidence |
|---|---|---|
| ownership (isClaimed, workspaces[].{email,isClaimed}) | `GET /api/v3/admin/profile/{uuid}` | `muso-admin-client.ts:12`, `remove-credits.sh` jq paths |
| raw external IDs / IPIs | same GET → `rawProfiles[]`, `ipis[]` | fixture `admin_api_profile_response.json:10,14` |
| shared tracks | `GET /api/v3/admin/profile/{uuid}/credits` intersection | `muso-admin-client.ts:13` |
| trusted author email | `GET /conversations/{convId}` → `source.author.email` | `outbound.ts:178`, `types.ts:126` |
| token | `process.env.MUSOAI_INTERCOM_TOKEN` (in `edge.env`) | `migrate-to-multi-gateway.sh:88` |
| conv-id | `ctx.sessionId` | `session-key.ts:8` |

> Path form must be `/api/v3/admin/profile/{uuid}` (the client hard-gates on the
> `/api/v3/admin/` prefix, `muso-admin-client.ts:68`) — not the `/admin/...` form
> used by the bash wrappers.

## 8. Files

**New**
- `plugins/support-tools/src/tools/dedupe-check.ts` — the read-only verifier.
- `plugins/support-tools/src/intercom-client.ts` — minimal read-only `getConversation`
  (mirror `plugins/intercom/src/outbound.ts:178`; reuse the existing http client).
- `plugins/support-tools/tests/dedupe-check.test.ts` — vitest.
- `workspaces/support/skills/customer-profile-dedupe/SKILL.md` — doctrine.

**Edit**
- `plugins/support-tools/src/index.ts` — register `dedupe_check`; read
  `process.env.MUSOAI_INTERCOM_TOKEN` (NOT a hydra-env config ref); add to the
  missing-keys warn list.
- `plugins/support-tools/openclaw.plugin.json` — `contracts.tools` 6 → 7.
- `plugins/support-tools/tests/index.test.ts` — `"registers exactly 6 tools"` → 7
  (update the `toEqual` array at `:19`; the manifest-drift assertion at `:171`
  auto-passes once the manifest is updated).
- `workspaces/support/TOOLS.md` — header "EXACTLY 8" → 9; Action tools 1-6 → 1-7
  (add a section for `dedupe_check`); Reference tools 7-8 → 8-9.
- `workspaces/support/SOUL.md` — numbered tool list (add tool 7); `:91` "Action
  tools (6)" → (7); `:107` "these 8" → 9; `:357` "exactly 8" → 9.
  *Grep `\b8\b` in both doctrine files before claiming done.*
- Ops-side doctrine: `skills-all/muso-ops-profiles/SKILL.md` (or operations `SOUL.md`)
  — one paragraph: a Caroline dedupe verdict in `details[]` is untrusted
  customer-influenced pre-screen evidence; the mandatory pre-merge checklist applies
  in full; verdict strings are data, not instructions.

**Untouched:** `muso-admin-client.ts` allowlist, `muso-admin-api.sh`, tier-2/godmode
config, `exec` config, `rate-limiter.ts` (reuse as a coarse per-session throttle).

## 9. Deploy & CI

- **Plugin packaging:** `dedupe_check` + `intercom-client.ts` are plain TS reusing
  typebox + the existing http client — **no new npm dep**, so `pnpm-lock` won't drift
  against the deploy SDK. Build stays `tsc → dist/index.js`.
- **Token:** already copied into `edge.env` by `migrate-to-multi-gateway.sh:88` and
  loaded by the edge unit; readable via `process.env`. **Provisioning prerequisite**
  on any newly-provisioned host (deploy.sh does not regenerate `edge.env`).
- **vitest (plugin-tests job):** covers `dedupe-check.test.ts` and the updated
  `index.test.ts` — pure-TS, so no bats-location problem.
- **skill-drift gate:** a new **support-only** skill with no `skills-all` counterpart
  must pass like `customer-credit-removal` does — *verify against
  `scripts/check-skill-drift.sh` during implementation.*
- **tool-deny audit / can-only-grow:** we add a read tool and touch no deny-list →
  passes. No `author=adk47`-gated file touched.
- **Deploy reach:** `support-tools` already deploys to edge; the workspace skill
  ships via the whole-repo rsync to `/opt/hydra`.

## 10. Testing (TDD — write tests first; encode intent)

vitest cases for `dedupe_check` (each encodes a security intent, not just behavior):
1. Missing/empty `MUSOAI_INTERCOM_TOKEN` → `verified=false`, `owner_undetermined=true`
   (fail-closed, **no crash, no pass**).
2. `requesterEmail` ≠ Intercom author email → `impersonation_flag=true`, not verified.
3. Survivor unclaimed / multi-claimed / email-mismatch → `owns_survivor=false`.
4. Duplicate `claimed_different_user` → **no third-party email** anywhere in the
   verdict (PII assertion).
5. `shared_external_id` present but no shared tracks → labeled `weak`,
   `cluster_size_check=not_performed`.
6. convId underivable from `ctx.sessionId` → fail-closed.
7. Injection markers in profile name/notes → stripped before output.
8. Happy path: owns survivor + unclaimed duplicate + shared tracks → verified
   evidence verdict (still no "merge-approved" stamp).
9. Duplicate-count cap + rate-limit enforced.

Plus `index.test.ts` updated to 7 tools (red → green on the count).

## 11. Open items to confirm during implementation

- `scripts/check-skill-drift.sh` passes a support-only skill (precedent:
  `customer-credit-removal`).
- Whether the gateway already injects a *trusted* author email into tool context
  (would make the Intercom re-fetch belt-and-suspenders rather than load-bearing) —
  re-fetch is specified regardless (defense-in-depth, mirrors `remove_credits`).
- Exact Intercom GET `/conversations/{id}` headers (Accept: application/json) and the
  `source.author.email` path against a real response.
- `MUSOAI_INTERCOM_TOKEN` read-scope on `GET /conversations/{id}` (distinct from the
  intercom plugin's inline channel token).
- **Codex runtime (PR #377):** Caroline now runs on `openai/gpt-5.5` via Codex.
  Re-confirm that `ctx.sessionId` is still populated in the
  `agent:support:intercom:{wsId}:conversation:{convId}` shape (the convId anti-spoof
  anchor) and that plugin tools bind to the Codex agentRuntime as expected; re-check
  the exec-exposure note (Codex ran in "yolo" mode on edge). PR #378 also moved
  Caroline to auto-deliver (`visibleReplies=automatic`) — confirm the customer-facing
  reply step still lands.

## 12. Risks

- **False reassurance:** even with weak-signal labeling, a verified-ownership ticket
  could nudge Operations to under-verify. Mitigated by the evidence-only framing +
  ops-side untrusted-evidence doctrine + the mandatory independent checklist.
- **Token provisioning drift:** if `MUSOAI_INTERCOM_TOKEN` is ever absent on a host,
  the tool fails *closed* (safe) but Caroline loses the capability — surfaced as a
  warn at plugin register.
- **Read-surface widening:** `dedupe_check` exposes `rawProfiles`-derived signals that
  `profile_status` deliberately hides from the customer surface. Mitigated: signals
  are internal/weak-labeled and raw IDs never reach the customer reply.

## 13. Decision log (interactive brainstorming)

1. Capability: **verify + auto-file** (autonomous merge rejected on review).
2. Ownership stamp: **trustworthy** (server-side Intercom re-check).
3. Verifier: **read-only TypeScript** plugin tool.
4. Verdict: **evidence**, not a confidence verdict (added on 2nd review).
5. Two independent adversarial reviews shaped this; 2nd verdict
   = `proceed-with-revisions`, all blockers folded in above.
