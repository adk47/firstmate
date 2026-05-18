# verify-credit-batch-mvp.lobster — Lobster MVP for credit verification.
#
# The ${dry_run} arg controls whether the apply step writes to the admin API.
# dry_run="true" (default): pipeline emits a Slack summary of what it WOULD do.
# dry_run="false": apply-verdicts.sh bulk-PUTs the would_approve bucket.
#
# Trigger paths:
#   1. @-mention in Slack: operations SKILL.md dispatcher invokes lobster
#      tool with this pipeline + batch_size + thread_ts.
#   2. Direct HTTP for testing:
#      curl -X POST http://127.0.0.1:18789/tools/invoke \
#        -H "Authorization: Bearer $(jq -r .gateway.auth.token /root/.openclaw-main/openclaw.json)" \
#        -H "Content-Type: application/json" \
#        -d '{"tool":"lobster","action":"run","args":{
#              "pipeline":"/opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/pipelines/verify-credit-batch-mvp.lobster",
#              "argsJson":"{\"batch_size\":5,\"thread_ts\":\"\"}",
#              "timeoutMs":700000}}'

name: verify-credit-batch-mvp

args:
  batch_size:
    default: 500
  thread_ts:
    default: ""
  dry_run:
    default: "false"
  selector_kind:
    default: "queue"
  selector_id:
    default: ""

env:
  ADMIN_API_SH: /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh

steps:
  - id: pick
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/pick-credits.sh ${batch_size} ${selector_kind} ${selector_id}

  - id: score
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/score-backend-signals.sh
    stdin: $pick.stdout

  # mb_lookup step removed 2026-05-18: it contributed 0 mb_confirmed
  # approvals on the prior real-apply run while consuming ~8 of 11 min
  # wall-clock. signal_review credits now route directly to UVN via
  # verdict-engine. The MB scripts (run-mb-batch.sh, musicbrainz-isrc-
  # lookup.sh) remain on disk for ad-hoc debugging.

  - id: verdict
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/verdict-engine.sh
    stdin: $score.stdout

  - id: apply
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/apply-verdicts.sh ${dry_run}
    stdin: $verdict.stdout

  - id: summary
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/render-dry-run-summary.sh
    stdin: $apply.stdout
    env:
      THREAD_TS: ${thread_ts}
