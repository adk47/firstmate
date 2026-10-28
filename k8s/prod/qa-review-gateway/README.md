# qa-review-gateway: the `qa` agent as its own gateway pods (node8-to-pods T9)

2026-10-28. The cluster objects (Deployment, HPA 2→6, Service, policies, CronJobs) live in
H-DevOps `k8s/prod/hydra-qa/`. Its README has the readiness table, the canary and the revert.
This directory holds what each pod runs, so it ships with the hydra tree baked into the image:

- `openclaw-qa.json` is the gateway profile. It has only the `qa` agent, no channels, the
  Control UI off, no chat-completions endpoint, `tools.exec.mode: "auto"` (not `full`), the
  minimum plugins (`codex`, `openrouter`), and **no token**: `OPENCLAW_GATEWAY_TOKEN` comes from
  the pod's own ESO-minted Secret.
  It sits here, not at the repo root, on purpose. `scripts/check-gateway-profile-parity.sh` treats
  every root `openclaw-*.json` as a node-8 profile that `deploy.sh` must start.
  The `qa` agent block, `models`, `auth.order` and the default model must stay equal to
  `openclaw-main.json`; `scripts/tests/qa-review-gateway-profile.bats` fails on drift.
- `entrypoint.sh` runs four steps in order: (1) refuse a short token or one of Caroline's
  literal tokens; (2) install and validate the profile; (3) run `openclaw doctor --non-interactive`
  (never `--fix`, which fans codex auth out into every agent store); (4) import the codex access
  token with `scripts/codex-auth-secret.sh import` (sentinel refresh slot only), then exec the gateway.

The related script changes:
- `scripts/qa-dispatch-pr-review.sh` targets a remote gateway when `OPENCLAW_GATEWAY_URL` is set
  (token from `OPENCLAW_GATEWAY_TOKEN` or `OPENCLAW_GATEWAY_TOKEN_FILE`, env only, never argv).
  When it is unset, behaviour is unchanged (`--profile main`), and unsetting it is the revert.
- `scripts/qa-review-reconcile.sh` unions every replica's cron store
  (`QA_RECONCILE_GATEWAY_PEERS_DNS`). A peer that fails to list makes the set unknown; it is
  never read as "job absent".
- `scripts/codex-auth-secret.sh` has two sides. On the writer side (`publish`) it runs
  `lib/codex-edge-mirror.sh` against a scratch target and applies Secret `hydra-qa/qa-codex-auth`.
  On the pod side (`import`) it writes that payload into the pod's own cell.
