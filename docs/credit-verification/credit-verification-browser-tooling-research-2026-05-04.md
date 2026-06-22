# Credit verification browser tooling research - 2026-05-04

## Question

How do we make sure the AI actually uses a browser and collects useful Tier-1 evidence, instead of claiming it did?

## Sources reviewed

- Playwright MCP capabilities: https://playwright.dev/mcp/capabilities
- Playwright ARIA snapshot docs: https://playwright.dev/docs/aria-snapshots
- Browser Use OpenClaw integration: https://docs.browser-use.com/cloud/tutorials/integrations/openclaw
- Browser Use stealth/proxy docs: https://docs.browser-use.com/cloud/guides/browser-api
- Browserbase Stagehand quickstart: https://docs.browserbase.com/welcome/quickstarts/stagehand
- Browserbase browser core features: https://docs.browserbase.com/platform/browser/core-features/overview
- Chrome DevTools Protocol: https://chromedevtools.github.io/devtools-protocol/
- WebDriver BiDi reference: https://developer.mozilla.org/en-US/docs/Web/WebDriver/Reference/BiDi

## Findings

### Playwright is the best deterministic test/evidence harness

Playwright MCP exposes browser navigation, accessibility snapshots, screenshots, network requests, tabs, and code execution. With the testing capability enabled, it also exposes assertion tools such as visible text and visible element checks.

Playwright's ARIA snapshot API is useful for our case because it turns rendered pages into a structured accessibility-tree representation. That is closer to OpenClaw's browser snapshots than raw HTML, and it is mechanically assertable.

Use Playwright for:

- local regression tests
- fixture generation
- deterministic `open -> wait -> snapshot -> extract` scripts
- trace/video debugging when a source page changes

Do not use Playwright MCP alone as the production trust boundary. It is still a tool an agent can skip unless scripts and summary gates require its artifacts.

### Browser Use Cloud is the most direct OpenClaw production upgrade, but it is paid

Browser Use has an OpenClaw-specific integration. It can be connected through OpenClaw's native browser tool via a remote CDP profile. That means the existing `openclaw browser open/snapshot/screenshot` commands can target Browser Use cloud browsers without rewriting the skill around a new API.

Relevant documented properties:

- OpenClaw can point its built-in browser tool at Browser Use through a CDP WebSocket URL.
- Browser Use documents cloud browser sessions with stealth, CAPTCHA solving, and proxies.
- The OpenClaw integration supports query parameters such as `profileId` and `proxyCountryCode`.

Use Browser Use for:

- production OpenClaw browser backend
- CAPTCHA/anti-bot resistance
- stable remote browser sessions for cron
- retaining the browser-only Tier-1 rule while avoiding local Chromium fragility

Risk:

- It is a paid external dependency and introduces API-key/session management.
- It makes browser access better, but it does not by itself prove the agent used the browser. We still need artifacts and gates.

User preference as of 2026-05-04: do not use paid browser infrastructure. Treat Browser Use Cloud as out of scope unless explicitly approved later.

### Local Browser Use is free/open source, but not the first choice here

Browser Use Open Source is documented as a Python library that can run locally or self-hosted. Its MCP docs call the local stdio MCP server the free, open-source option. Browser Use terms say the GitHub software is MIT-licensed.

That means local Browser Use is viable if we want an AI-browser-agent abstraction without paying for cloud browsers. However, the current failure is not "we need a smarter browser agent." The failure is "the agent can skip or rewrite evidence." Adding another AI browser layer increases the number of model decisions unless we keep it behind deterministic scripts.

Use local Browser Use only if a quick spike proves it extracts rendered Tier-1 evidence better than Playwright/OpenClaw on the same fixtures. Do not make it the default dependency for this repair.

### Browserbase/Stagehand is promising but too high-level for the first fix

Browserbase Stagehand lets code mix Playwright-style control with model-assisted `act` and `extract`. Its session inspector can show AI decisions.

Use Stagehand later if we want a managed extraction layer with inspector traces. For the first repair, avoid moving credit verification into another AI extraction stack. The immediate need is deterministic evidence capture and refusal gates.

### Raw CDP is powerful but too low-level for this skill

Chrome DevTools Protocol exposes browser instrumentation domains including DOM, DOMSnapshot, Network, Page, Runtime, Accessibility, and Tracing. It is the substrate behind many tools.

Use raw CDP only if Playwright/OpenClaw/Browser Use cannot provide a needed primitive. It increases implementation surface area without solving agent shortcutting.

### WebDriver BiDi is not the fastest path

WebDriver BiDi provides bidirectional browser automation over WebSocket and supports real-time browser events. It is useful for cross-browser automation, but this workflow currently depends on Chromium-like rendered access and OpenClaw integration. Playwright/CDP-based paths fit better.

## Recommendation

Adopt a two-layer browser plan:

1. **Default local backend:** use local Chromium/Chrome driven by Playwright for deterministic evidence collection and tests.
2. **OpenClaw compatibility path:** keep `openclaw browser` as the runtime surface where needed, but make it write the same evidence JSONL artifacts as Playwright.
3. **Optional local Browser Use spike:** test local Browser Use only if Playwright/OpenClaw cannot reliably render or extract a Tier-1 source. Keep it free/self-hosted.

The important control is the artifact, not the browser vendor. A successful evidence row should include:

- `run_id`
- `profile_id`
- `credit_request_ids`
- `source_host`
- `url`
- `opened_at`
- `snapshot_len`
- `snapshot_hash`
- `contains_claim_name`
- `contains_track_title`
- `contains_role_token`
- `extract_status`: `matched`, `insufficient_evidence`, `tier1_unreachable`
- `failure_kind` when unreachable
- path to raw snapshot or trace artifact

## Tests needed

### 1. Fixture-level evidence classifier tests

Given session/evidence fixtures, assert:

- no browser calls -> no decisions allowed
- profile anchor only -> insufficient evidence
- one Spotify snapshot with no role/name markers -> insufficient evidence
- two Tier-1 snapshots with claim markers -> action allowed
- browser errors/captcha/5xx on two Tier-1 hosts -> `tier1_unreachable` allowed
- generic "credit card" UI copy does not count as credit evidence

### 2. Runlog/session cross-check tests

Before any `verdict`, `action_attempted`, or `escalation_posted` is accepted:

- there must be a run-scoped evidence row for that `profile_id`
- the evidence row must reference successful browser/openclaw/playwright artifact IDs
- the source hosts must meet the Tier-1 quorum
- the row must be sealed or hash-linked to immutable snapshot artifacts

### 3. Summary refusal tests

`post-batch-summary.sh` must refuse:

- `Escalated > 0` without escalation receipts
- `Fetched > 1` but browser evidence for only one profile
- runlog counts that exceed evidence/receipt counts
- unverified/tampered runlog

### 4. Tool-forcing tests

Add fixtures that simulate an agent using forbidden or inadequate tools:

- `web_fetch` against Tier-1 -> blocked
- `web_search` in credit-verification context -> redirected/refused
- shell command mutating runlog -> blocked by plugin guard, and still refused by runlog verifier if bypassed
- hand-written Slack summary -> blocked unless posted via summary script

### 5. Live smoke test

For a dry-run fetch size of 10:

- every processed profile must have an evidence JSONL row
- every evidence row must link to raw snapshot/trace files
- summary counts must be less than or equal to evidence-backed action/receipt counts
- the session log must include either OpenClaw browser calls to Browser Use CDP or deterministic collector script calls
- if all evidence is insufficient, Slack summary must say no writes and no fabricated escalations

## Implementation order

1. Add tests for the May 4 fixture: 10 browser calls for one profile cannot summarize 50 escalations.
2. Add deterministic evidence JSONL schema and classifier tests.
3. Add Playwright implementation for local deterministic tests, ARIA snapshots, screenshots, and traces.
4. Add script compatibility wrapper so OpenClaw runtime can call the same evidence collector.
5. Optionally spike local Browser Use against the same fixtures, with no cloud dependency.
6. Add live dry-run smoke test and make it part of release validation.
