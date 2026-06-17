# muso-cli Unification Migration Plan — hydra Fleet

_2026-06-16 · branch `feat/muso-cli-unification`_

Goal: replace hydra's scattered bash/scripts/skills that hit external systems
(Muso admin API, Trino, Slack, ClickUp, NocoDB, Intercom, Stripe, …) with the
single `muso` host binary — one authenticated, policy-gated, audited path.

This plan was produced by an 11-agent mapping workflow (2 CLI deep-maps + 9
hydra cluster inventories → synthesis → adversarial critic) and then
**re-verified by hand against the actual repos** — which corrected three
material claims in the raw output. Read §0 first; it changes the scope.

---

## 0. Premise correction — what muso-cli actually has TODAY

The request said "we now have v0.2.0." The true state, verified
(`git -C muso-cli`):

- **muso-cli `main` is 4 commits PAST the `v0.2.0` tag.** Tags: `v0.1.0`,
  `v0.2.0` (`f220de96`); `main` HEAD `32909df`.
- **At the `v0.2.0` tag**, the only callable third-party provider command is
  **`slack send|dm`**. `nocodb`/`clickup`/`intercom`/`stripe` commands do **not**
  exist there. (This is what the workflow analyzed — correctly, for the tag.)
- **On `main` (unreleased)**, **`nocodb` (#11) and `clickup` (#12) commands are
  already built and merged.** Files `internal/cli/nocodb.go`,
  `internal/cli/clickup.go` exist; `nocodb` IS in
  `internal/provider/registry.go`. So they are **release-and-pin** work, not
  build-from-scratch.
- **Genuinely net-new BUILD gaps:** only **Intercom** and **Stripe** commands.
  Both have registry `Spec`s in `internal/provider/registry.go` (+ dormant
  policy-tier rules for `ghl`/`n8n`/`cloudflare`) but **no cobra command**.
- The provider client already has **shared HTTP 429 / Retry-After / capped
  backoff** (`internal/provider/client.go`) — so every provider, present or
  future, inherits rate-limit safety.

**Net:** the engineering frontier is **2 new provider commands (Intercom,
Stripe)** + a release cut for the two already-built ones + a handful of small
flags + one policy decision (the credit browser-evidence gate). Everything else
is mechanical swaps or already done.

> Operational note: a mapping agent left the muso-cli checkout **detached at
> `v0.2.0`** while inspecting the tag. It has been restored to `main`. When
> quoting "what muso-cli has," always say whether you mean the **tag** (what's
> deployed via the pin) or **`main`** (what's merged).

---

## 1. Executive summary

- **The Muso admin API is essentially solved.** Typed commands (`profiles`,
  `tracks`, `users`, `teams`, `claiming`, `credit-requests`, `identity`) plus
  the generic `muso api <METHOD> /admin/<path>` escape hatch (**184 routes**)
  cover effectively every `/admin/*` call the ops-* skills make. The codex
  model-health gate is preserved post-migration via
  `scripts/muso-prewrite-hook.sh` → `scripts/lib/codex-health.sh`, which fires
  before **every** write (and will auto-cover future Stripe/Intercom writes).
- **Trino is solved at the engine level.** `muso query` is a 1:1 kubectl-exec
  reproduction; the dedup lib and the weekly fleet-fraud cron already run on it.
- **Slack write is largely done.** `scripts/lib/slack-notify.sh` (the keystone,
  sourced by ~6 watchdogs) and the bash callers already shell to
  `muso slack send|dm`; `slack send` supports Block Kit (`--blocks-file`),
  `--thread-ts`, `--no-unfurl`, `--bot`.
- **The frontier:** Intercom + Stripe commands don't exist; ClickUp + NocoDB
  exist but are unreleased; **Slack read** methods don't exist; and one wrapper
  control — the credit-request **browser-evidence** gate — is not ported.

**Already-shipped controls (do NOT re-build):** the profile-merge
reverse-direction guard (`internal/policy/mergeguard.go`) and the
bulk-destructive DELETE cap (`internal/policy/bulkcap.go`) **are** ported and
wired fail-closed into `gate.go` (`Check()`/`After()`). `muso api --file`
multipart **exists** (field name hard-coded `"file"`). These were flagged as
gaps in the raw workflow output; verification proved them already done.

**Rough coverage tally** (~70 candidate call-sites):

| Status | ≈Count | Where |
|---|---|---|
| already-migrated | ~14 | dedup lib (5 Trino + 1 admin), slack-notify keystone + bash callers, prewrite-hook, fleet-fraud cron |
| covered (clean swap, no new CLI) | ~10 | most ops-* admin skills, read-only Trino skills, 3 ops Trino scripts |
| partial (one leg covered) | ~14 | mixed Trino+ClickUp / Slack+ClickUp / Slack+Intercom scripts |
| gap → needs CLI work | ~22 | Intercom (build), Stripe (build), ClickUp/NocoDB (release+flags), Slack-read |
| not-a-candidate (infra/doctrine) | ~13 | watchdog bodies, jq helpers, doctrine skills, edge webhook |

---

## 2. Coverage matrix (by external system)

| System | hydra call-sites | Status | muso-cli path | Blocker |
|---|---|---|---|---|
| **Muso admin API** | ~12 ops-* skills + dedup `fetch-profile.sh` + credit-sync | covered / already-migrated | typed cmds; `muso api <M> /admin/<p> --requester <e>` | only **credit-approve** fenced (evidence gate); Slack-ID→email resolver still wrapper-side |
| **Trino** | `trino-query.sh` + dedup `lib/*` + scans + fleet-fraud cron + 3 ops scripts + `merge-landing-watchdog` | covered; dedup+cron already-migrated | `muso query "<SQL>"` / `--format json` / `-` (stdin) | legacy-name **hint-only** (no rewrite) → ~20 saved `.sql` on bare legacy names fail; CSV header vs `tail -1`; node-8 kubectl |
| **Slack (write)** | `slack-notify.sh` + bash callers (done); 4 Python notifiers (pending) | already-migrated / covered | `muso slack send --bot --channel --text/--blocks-file/--thread-ts`; `slack dm` | Python notifiers read botToken from `openclaw.json` → swap to env; deploy must export `--bot` token |
| **Slack (read)** | `scan-unanswered.py`, `retrigger-unanswered.py`, `openclaw-restart-notify.sh`, `hydra-daily-audit.py` | **GAP** | none (only postMessage + conversations.open) | needs `slack raw GET` or read subcommands (G6) |
| **ClickUp** | `clickup-sla-digest.sh`, `stale-ticket-watchdog.sh`, `close-merged-tickets.sh`, `notify-merged-customers.py`, `muso-clickup` | **built on main, unreleased** | `muso clickup tasks …` / `clickup raw` | needs **release + pin bump**; add auto-paginate (G2a) before cutover |
| **NocoDB** | `nocodb-api.sh` + `company-finder/{dedupe,ledger,migrate,setup}` + `lib/common.sh` + `muso-nocodb` | **built on main, unreleased** | `muso nocodb records/tables/raw` | needs **release + pin**; add `records ls --all` (G3a) for the ≤100 clamp (#510) |
| **Intercom** | `close-resolved`, `fetch-conversations`, `intake-watchdog`, `audit-attachments`, `check-customer-replied`, `notify-merged-customers`, `abuse-block.py`, `muso-intercom`; **`intercom-webhook.js` (EDGE)** | **GAP — build** | _target:_ `muso intercom convs search/get/reply/close/tag` + `contacts/tags` + `intercom raw` | no command (Spec only); edge webhook non-migratable |
| **Stripe** | `muso-stripe-write.sh`, `muso-stripe`, `-disputes`, `payout-*`, `muso-contract-invoicer` | **GAP — build** | _target:_ `muso stripe refunds/disputes/customers/subscriptions/invoices` + `stripe raw` | no command (Spec only); money path needs model-health preflight (G5a) |
| **Other SaaS** (Anrok, Deel, DocuSign, ChartMogul, ProfitWell, Rewardful, Amplitude, Klaviyo, Cloudflare, GHL, Gmail) | ~20 skills/scripts | **GAP / leave-as-is** | none | mostly read-only reporting → leave; write/governance ones are Tier-3 |

---

## 3. CLI gap-fill backlog (corrected, ranked)

Effort: S ≈ ½ day · M ≈ 1-2 days · L ≈ 3-5 days.

### Tier 1
- **G-REL. Cut a muso-cli release (shipped as v0.3.0) including #11 nocodb + #12 clickup,
  bump the hydra `MUSO_CLI_VERSION` pin in `deploy.sh`.** _Effort S._ Unblocks
  the entire ClickUp + NocoDB swap with zero new Go code. **Prerequisite for
  Batch B.**
- **G3a. NocoDB `records ls --all` auto-paginate** — _S._ `nocodb.go` has
  `--limit/--offset` but no `--all`; NocoDB Cloud silently clamps `limit≤100`
  (the #510 dedup-truncation bug). Without this, a 1:1 swap regresses.
- **G2a. ClickUp `tasks ls` auto-paginate** (or forward `?page=N` via `raw`) —
  _S._ Ops board is 2000-4500 tasks → `PAGINATION_CAP` blows otherwise.
- **G1. `muso intercom` provider command** — _M._ `convs search --query-file
  <json>` (raw AND/OR body + cursor paginate + NDJSON), `get [--plaintext]`,
  `reply --admin-id --comment`, `close`, `tag/untag`, `contacts`, `tags`, plus
  `intercom raw`. Single biggest provider gap (~7 main-host call-sites).
  Sub-item **G1a (S):** extend `provider_tiers.go` to gate
  `POST /conversations/{id}/reply` and `…/parts` (close) — current rule only
  gates `POST /messages`, so customer-facing writes would go out write-tier
  only.

### Tier 2
- **G5. `muso stripe` provider command** — _L._ `refunds/disputes/customers/
  subscriptions/invoices/coupons` + read-only `charges/balance_transactions`
  + `stripe raw`. Sub-item **G5a (M):** model-health preflight for
  dangerous-tier money writes (port `codex-health.sh` intent into the policy
  layer / rely on the prewrite hook) — without it, `stripe refunds create`
  regresses the 2026-06-08 hallucinated-refund protection.
- **G4a. Credit-request browser-evidence gate** — _L._ Port the session-log
  browse-quorum + web_fetch block + jan/aaron human-override into the prewrite
  hook, branching on `PUT /admin/credit-requests status=approved`. Until then,
  **keep credit-approve on `muso-admin-api.sh`.** Note: a migrated approve is
  **still** gated (TierApproval needs `--confirmed-by`/`--approval-ref` +
  codex-health) — it is "gated but evidence-blind," _not_ ungated.
- **G6. Slack read** — _M_ (S for `slack raw GET /api/<method>`). Unblocks the
  unanswered-scan scripts. Lower priority (courtesy/audit, not incident paths).

### Tier 3
- **G7. Multipart field-name** — _S._ `muso api --file` exists but the part name
  is hard-coded `"file"`; some endpoints want `image`. Verify per upload
  endpoint; add `--file-field` only if needed. (Was mis-scoped as "build
  multipart" — it already works.)
- **G8. Slack-ID→email resolver in `--requester`** — _S._ Drops the last
  wrapper dependency from the 3 already-migrated skills.
- **G9. `muso query --rewrite-legacy` (opt-in) + `--dry-run`** — _S._ vs. a
  one-time SQL-name sweep in hydra (see D4).
- **G10. `muso query --no-header`** — _S._ For CSV `tail -1` callers
  (`--format json` already sidesteps).
- **G11. Verify `/w/admin/ads` + `/c/v4` route family** — _S to verify._
  ads-manager uses a non-`/admin/*` path family; `muso api` (184 `/admin`
  routes) may not reach it.
- **G12. Greenfield SaaS providers** (DocuSign, Anrok, Deel, GHL) — _M each,_
  governance-driven, low frequency. See D5.

---

## 4. Constraints that shape sequencing

1. **Edge-vs-main split.** Binary lives on the node-8 **main** gateway only;
   Caroline/edge agents are exec-denied. `scripts/intercom-webhook.js` runs on
   **edge** and is **non-migratable** (long-running HMAC listener; effectively
   an openclaw plugin). Every other in-scope script runs on main-host
   crons/timers.
2. **Cron PATH misses `/usr/local/bin`.** Newly-migrated cron callers must pin
   `MUSO_BIN=/usr/local/bin/muso` or source `slack-notify.sh` (which already
   absolutizes). `install-aux-units.sh` already pins it on
   `close-merged-tickets.service`.
3. **Token-env split.** SLA-digest + close-merged units load
   `shared.env`+`edge.env`, **not** `main.env`. Provider token resolution must
   work there. `MUSO_REQUESTER` must **never** be a static env var (kills
   attribution) — cron callers pass `--requester <name>@hydra-ops` explicitly.
4. **Soak already underway.** `muso-ops-claiming`, `muso-audit-profile-credits`,
   `muso-ops-credit-sync`, the dedup Trino+admin legs, and the fleet-fraud cron
   are migrated. Finish in-flight batches before opening new fronts.
5. **Credit-approve fenced** behind G4a (evidence gate) — reject/list/counts are
   safe now.
6. **NocoDB ≤100 clamp** — G3a is a hard prerequisite, not nice-to-have.
7. **Cloudflare WAF / node-8-only** for all admin HTTP + `muso query`. No
   test-from-laptop path; live parity is verified on node-8.
8. **`MUSO_NONINTERACTIVE=1`** fleet-wide — dangerous writes must pass
   `--yes`/`--confirmed-by` explicitly; EOF = "no."

---

## 5. Batched cutover sequence

### Batch A — finish domain ops-* skills off the wrapper _(no new CLI; lowest risk)_
Migrate `muso-ops-identity` (start here), `-workspaces`, `-users`, `-credits`
(**reject/list/counts only**; approve fenced by G4a), `-profiles`
(**incl. merge — gate is shipped**), `-tracks` (**incl. analytics-source DELETE
— bulk-cap is shipped**). Residual: place `bulk-destructive-exclude.txt` in
muso's `ConfigDir` and `recent-merges.jsonl` + audit log in its `StateDir`
(config-placement, S each). Verify: per-skill live read-diff vs wrapper;
`--dry-run` writes; bats where present.

### Batch B — ClickUp + NocoDB _(release + pin, then mechanical swaps)_
**Prereq:** G-REL (cut v0.3.0 with #11/#12, bump pin) + G3a + G2a. Then:
introduce a `USE_MUSO_CLI` seam in `scripts/company-finder/lib/common.sh`
`run_nocodb` (flips all four scripts at once), cut over `dedupe-candidates`,
`ledger`, `migrate-normalize-domains`, `setup-ledger-table`, `muso-nocodb`;
ClickUp leg of `clickup-sla-digest.sh`, `stale-ticket-watchdog.sh`,
`close-merged-tickets.sh`, `muso-clickup`. Risk: medium — gate cutover on a
golden test asserting a >100-row NocoDB fetch and a multi-page ClickUp list.

### Batch C — Stripe _(build, then migrate the money path)_
**Prereq:** G5 + **G5a (blocking)**. Migrate `muso-stripe-write.sh`,
`-disputes`, `muso-contract-invoicer`, read-only payout reports. Risk: high
(irreversible writes) — do not ship until G5a fail-closes on degraded model
exactly as `muso-stripe-write.sh` does today. Keep the $500/5-per-day refund
rails skill-side or add as Stripe tier flags.

### Batch D — Intercom _(build; gated on D1)_
**Prereq:** G1 + G1a. Migrate main-host scripts only: `check-customer-replied`
(easy first), `audit-credit-claim-attachments`, `fetch-conversations`,
`intake-watchdog` (Intercom leg), `close-resolved-conversations`,
`notify-merged-customers`, `abuse-block.py` (best candidate — its hand-rolled
audit/requester/dry-run collapses onto muso). **Leave** `intercom-webhook.js`
(edge). Risk: medium-high (customer-facing) — golden-test the search body
passthrough + the `conversation_parts` projection.

### Batch E — Slack-read + long-tail SaaS
G6 unblocks the unanswered-scan scripts. SaaS providers per D5. Most read-only
reporting SaaS: leave-as-is.

---

## 6. Explicitly out-of-scope / leave-as-is
Pure infra/orchestration bodies (`openclaw-watchdog.sh`, `cron-health-watchdog`,
`fallback-swallow-watchdog`, `prod-log-alert-watchdog`, `install-aux-units`,
`openclaw-pre-start-heal`, `codex-usage-report`, `rotate-slack-tokens`) — their
only candidate was Slack egress, already done. Pure jq/CI helpers
(`dedup/lib/{normalize,score,expand}`, `company-finder/{verify,check-argv}`).
Edge `intercom-webhook.js`. Doctrine/reference skills (text refresh only).
Read-only reporting SaaS (ChartMogul, ProfitWell, Rewardful, Amplitude,
Cloudflare-read, Klaviyo-read) — a provider buys no safety; if ever needed, one
generic `muso saas-get <provider> <path>` covers all at once.

---

## 7. Open decisions for Nick
- **D1 — Build the Intercom provider** even though the heaviest traffic
  (`intercom-webhook.js`) stays Python-on-edge? Covers ~7 main-host scripts.
  _Lean: yes, build for main-host; re-home the webhook separately if ever._
- **D2 — Port the credit browser-evidence gate (G4a, L)**, or keep approve on a
  thin wrapper shim permanently? A migrated approve is still
  approver+model-health gated, just evidence-blind. _Lean: shim short-term,
  port eventually._
- **D4 — Legacy-SQL: one-time hydra sweep vs `muso query --rewrite-legacy`
  flag?** _Lean: the sweep (hydra-local, CI-verifiable, keeps CLI semantics
  pure) unless un-enumerable bare-legacy SQL exists._
- **D5 — Which SaaS beyond Stripe to provider-ize?** _Lean: DocuSign yes
  (kills the reinvented JWT-grant/token-cache), Anrok bundle-with-Stripe,
  Deel/GHL only on a governance push, Gmail no (per-user gog OAuth ≠ muso auth
  model)._

(D3 from the raw workflow — "are mergeguard/bulkcap ported?" — is **resolved**:
they are. No action.)

---

## Key file references
- Keystone Slack lib: `scripts/lib/slack-notify.sh`
- Wrapper muso-cli replaces: `skills-all/muso-ops-admin/scripts/muso-admin-api.sh`
- Gate home: `scripts/muso-prewrite-hook.sh` + `scripts/lib/codex-health.sh`
- NocoDB seam: `scripts/company-finder/lib/common.sh`
- Unit installer / `MUSO_BIN` pin: `scripts/install-aux-units.sh`
- Deploy pin: `scripts/deploy.sh` (`MUSO_CLI_VERSION`)
- muso-cli (`Muso-AI/muso-cli`): `internal/provider/{registry,client,creds,slack}.go`,
  `internal/policy/{gate,tiers,provider_tiers,mergeguard,bulkcap}.go`,
  exemplar command `internal/cli/slack.go`, generic API `internal/cli/api.go`,
  Trino `internal/trino/legacy.go`.
