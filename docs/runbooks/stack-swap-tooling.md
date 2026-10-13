# Stack swap, lane 8: internal tooling off Klaviyo / Amplitude / Knock

**Context.** Muso is moving email from Klaviyo to send-gateway + preferences + Listmonk
(Mailgun / SMTP2GO), notifications from Knock to notify-gateway + Novu, and analytics from
Amplitude to the event router + ClickHouse (repo `Muso-AI/muso-messaging`). Lane 8 moves
the *internal* readers (hydra agents, saved SQL, runbooks, CLIs, admin panels). It was
listed as never dispatched in Fable's r2 re-survey (2026-10-13, section 4, lane 1).

**Rule for every surface: read from both, prefer ours, until that channel cuts over.**
The vendor path stays working until the channel's cutover. Every answer names its source.
The vendor fallback is removed only in the cleanup step for that channel (below), never
before.

## How agents read our stack

`scripts/muso-stack-read.sh` (deployed to `/opt/hydra/scripts/`), read-only by design:

| Subcommand | Reaches | Read-only control |
|---|---|---|
| `coverage` | all of the below | measures what our stack holds right now; agents run it before preferring a new source |
| `router '/api/2/...'` | event router admin port `messaging/svc/event-router-admin:8081` via `kubectl port-forward` | GET only, five-path allow-list, Basic `hydra:` pair over stdin |
| `ch '<SELECT>'` | ClickHouse `product-analytics` (`product_events.*`, `messaging.email_events`) via `kubectl exec` | `clickhouse-client --readonly=1`, 60 s, 100k rows |
| `pg <notify\|preferences\|listmonk> '<SELECT>'` | messaging Postgres **replica** via `kubectl exec` | asserts `pg_is_in_recovery()`, then `default_transaction_read_only` |

A statement guard refuses anything that is not one SELECT/WITH/SHOW/DESCRIBE/EXPLAIN.
Tests: `scripts/tests/muso-stack-read.bats` (hermetic stubs).

Router credential: `MUSOAI_EVENT_ROUTER_QUERY` in `/etc/openclaw/main.env`, else the
Secret `hydra/hydra-event-router-query` (ExternalSecret of Vault
`secret/k8s/messaging/event-router-admin` property `query_hydra`,
https://github.com/Muso-AI/H-DevOps/pull/4025). Neither present = exit 3 and agents fall
back to the vendor and say so.

Why port-forward: the admin port is fenced to `muso-prod` / `monitoring` / `messaging`
(H-DevOps `k8s/prod/messaging/80-event-router.yaml`), and hydra runs as systemd on node-8,
not in a pod. node-8's kubectl is how `scripts/trino-query.sh` reaches Trino too.

## Checklist (state as of 2026-10-13)

| # | Surface | Was | Now | State | Link |
|---|---|---|---|---|---|
| 1 | `muso-amplitude` skill | Amplitude Dashboard API | new `muso-analytics` skill (router query API + ClickHouse); `muso-amplitude` kept as a labelled fallback | DONE in this PR | this PR |
| 2 | `muso-klaviyo` skill | Klaviyo API | new `muso-email` skill (email_events, preferences, send log, flows, Listmonk); `muso-klaviyo` kept as fallback (writes remain Aaron/Nick for streams still on Klaviyo) | DONE in this PR | this PR |
| 3 | `cmo-eod` | Klaviyo 24h activity | our stack first per stream, Klaviyo for streams not cut over, never double-count | DONE in this PR | this PR |
| 4 | `muso-ops-users` step 4 | Amplitude | `muso-analytics` usersearch/useractivity | DONE in this PR | this PR |
| 5 | `muso-refund-investigation` step 5, `muso-refund-processor` | Amplitude curl | `muso-analytics`, Amplitude for uncovered windows | DONE in this PR | this PR |
| 6 | `muso-stripe-disputes` engagement evidence | Amplitude curl | `muso-analytics` | DONE in this PR | this PR |
| 7 | Retool runbook (`muso-clio/references/operations/retool.md`) user lookup + bulk login sends; `muso-ops-workspaces` bulk sends | "paste id in Amplitude"; "use Klaviyo" | `muso-analytics`; bulk sends = human, Klaviyo until marketing cutover then Listmonk | DONE in this PR | this PR |
| 8 | TOOLS.md (cmo, coordinator, cto), `coordinator/INTEGRATIONS.md`, `shared-reference/API-CONFIGS.md` (Knock, Amplitude lookup rule) | vendor-only | our stack listed first, vendors marked legacy; Knock bell read from `notify.feed_items` | DONE in this PR | this PR |
| 9 | `openclaw-main.json` operations skill allow-list | `muso-amplitude` | + `muso-analytics`, `muso-email` (fallback kept) | DONE in this PR | this PR |
| 10 | Saved SQL: `muso-query-writer/saved-queries/{export/klaviyo_users_stats, misc/muso_user_rank, misc/amplitude_user_cohorts, email/lite_users_with_country_discount}.sql`, `shared-reference/queries/churned_pro_{5mo,campaign}.sql` | Klaviyo/Amplitude upload audiences; Amplitude lake reads | SQL unchanged (reads Muso tables / the lake, which the router keeps filling at cutover, analytics lane A11); headers say where the audience goes now (Listmonk) and to prefer ClickHouse for current reads | DONE in this PR | this PR |
| 11 | Router credential for hydra | none | ExternalSecret `hydra/hydra-event-router-query` | PR open | https://github.com/Muso-AI/H-DevOps/pull/4025 |
| 12 | ads-manager admin Amplitude panel (A3) | hard-coded `https://amplitude.com` | `AMPLITUDE_API_HOST` env, default unchanged | PR open | https://github.com/Muso-AI/ads-manager/pull/192 |
| 12b | ads-manager env flip | — | H-DevOps: `AMPLITUDE_API_HOST=http://event-router-admin.messaging.svc.cluster.local:8081`, `AMPLITUDE_TOKEN`/`AMPLITUDE_SECRET` = the halves of `query_ads_manager` | AT ANALYTICS CUTOVER (not before: the router view serves history only until the `cutover` row) | — |
| 13 | muso-cli | Fable listed `internal/provider/creds.go` "Klaviyo key" | no vendor credential or call exists: `creds.go` names Klaviyo only in a comment; `users.go` help text says an email change cascades to Klaviyo, which is **still true** (core-backend `updateUser`, K3) | NO CHANGE NOW; reword the help text when core's K3 cascade moves to preferences | — |
| 14 | `k8s/prod/monitoring/webhook-health-monitor.yaml` probe `klaviyo-event-webhook` | probes core's `/api/wh/klaviyo/event` | still a live endpoint (the pre-cancel scheduler webhook, K10) | KEEP until K10 moves to send-gateway `n_precancel`; then delete the probe line | — |
| 15 | Legacy web-credits (Nuxt) | see below | retirement plan below | NEEDS A GO (destructive) | — |

## Legacy web-credits retirement plan (N12)

Measured 2026-10-13 (correcting Fable r2, which said no Deployment exists):

- `muso-prod/credits` Deployment **exists**: 6/6 replicas, image
  `muso/web-credits:prod-20261008-284`, env includes `KNOCK_FEED_CHANNEL_ID` and the full
  `core-backend-config` + `db-muso-core` Secrets. All 6 pods idle (~0 CPU, 0 log lines in 1 h).
- `credits.muso.ai` → Ingress `credits-muso-ai` → `credits:3000`, but Cloudflare answers
  `301 → https://muso.ai/<path>` at the edge (`server: cloudflare`), so customers never reach it.
- `credits.ak.muso.ai` → `credits-ak-gate` (created ~2026-10-11, staff better-auth gate) →
  `credits:3000` with `API_BACKEND_URL` pointed at a void service: a deliberate staff-only,
  API-less view of the old app. It still loads the old app's Knock and Amplitude code in
  staff browsers.
- `muso-dev/credits-dev` (1/1) and ExternalSecret `muso-dev/web-credits-build`.
- H-DevOps: `.github/workflows/deploy-web-credits.yaml`, `k8s/prod/core-services/deployments.yaml`
  (credits Deployment/Service), `k8s/dev/argocd-managed/credits-dev/*`,
  `k8s/dev/web-credits-build-keys-eso.yaml`; repo `Muso-AI/web-credits` (private, not archived,
  last push 2026-10-09).

Plan (each step is one reviewable H-DevOps PR; every step is reversible until step 5):

1. Ask the owner of `credits-ak-gate` what it is for (it was set up two days ago). If it is
   needed, keep it and the `credits` Deployment at 1 replica; skip to step 4 for the rest.
2. Scale `muso-prod/credits` 6 → 1 (staff view only) and `muso-dev/credits-dev` → 0.
3. After 7 days without a request: remove the `credits` Deployment/Service and both Ingresses
   from `k8s/prod/core-services/deployments.yaml`. The Cloudflare redirect stays as the only
   `credits.muso.ai` behaviour.
4. Remove `deploy-web-credits.yaml`, `k8s/dev/argocd-managed/credits-dev/*` and
   `k8s/dev/web-credits-build-keys-eso.yaml`; delete the Vault build-key path only after the
   ExternalSecret is gone.
5. Archive `Muso-AI/web-credits` on GitHub (read-only, reversible by an org admin).

Knock and Amplitude cutovers do not depend on it: no customer traffic reaches the app.

## Per-channel cleanup (after each cutover, one hydra PR each)

**Analytics** (after the `cutover` row exists and Amplitude is downgraded, 30 Oct):
delete `skills-all/muso-amplitude/`, drop it from `openclaw-main.json` and every
`depends-on`, remove the Amplitude fallback sentences from the skills in rows 4-6, remove
`MUSOAI_AMPLITUDE_TOKEN` / `MUSOAI_AMPLITUDE_SECRET_KEY` from `/etc/openclaw/main.env`.

**Email** (after the last stream and marketing leave Klaviyo, ~28 Oct, and before the Klaviyo
token is revoked): delete `skills-all/muso-klaviyo/`, the Klaviyo sections of the TOOLS.md
files and INTEGRATIONS.md, the Klaviyo line of `cmo-eod`, `MUSOAI_KLAVIYO_TOKEN` from
main.env, and the `klaviyo-event-webhook` probe once K10 has moved.

**Notifications** (after Knock exit): drop the Knock rows from INTEGRATIONS.md and
API-CONFIGS.md.
