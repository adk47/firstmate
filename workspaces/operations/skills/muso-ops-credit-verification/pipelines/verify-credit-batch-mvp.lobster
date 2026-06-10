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
  # Raw-batch handoff file for the fraud step (see CV_FRAUD_RAW_BATCH below).
  # dispatch-cv-batch.sh passes a UNIQUE per-run path so two overlapping
  # batches (cron + manual @-mention) can never clobber each other's raw
  # batch and silently cross-score profiles. The static default only applies
  # to direct/manual invocations, which are a debugging-only path.
  raw_batch_file:
    default: "/tmp/cv-fraud-raw-batch.json"

env:
  ADMIN_API_SH: /opt/hydra/workspaces/operations/skills/muso-ops-admin/scripts/muso-admin-api.sh
  # Fraud detector (operations BATCH only — Caroline/customer-facing is OUT OF
  # SCOPE). Default OFF: the fraud step is a byte-for-byte pass-through no-op
  # until explicitly rolled forward to shadow, then enforce, mirroring the
  # proven CV_EVIDENCE_MODE flag-off rollout. See docs/credit-verification/
  # fraud-detection-spec.md. DO NOT set enforce in production until the
  # verdict-engine signal_fraud→would_uvn mapping ships (Phase 2) — with the
  # current engine a signal_fraud credit would be silently dropped.
  CV_FRAUD_MODE: "off"
  # The fraud scorer needs the RAW fetched batch (credits[], metadata.*,
  # profile.*, verificationData.* — fields score-backend-signals.sh drops).
  # The pick step tees its stdout here so the fraud step can re-read it without
  # modifying any existing script. Both the pick command and this env value
  # interpolate the SAME ${raw_batch_file} arg so the two steps always agree
  # (arg interpolation in env values verified live against the deployed
  # @clawdbot/lobster on node-8, incl. step-env merge); the tee is
  # byte-transparent, so $pick.stdout into score is unchanged.
  CV_FRAUD_RAW_BATCH: ${raw_batch_file}

steps:
  - id: pick
    # Lobster runs each command via `/bin/sh -lc` (verified against
    # @clawdbot/lobster runShellCommand), so a redirect + `&&` works here.
    # We write pick's stdout to the raw-batch file FIRST, then `cat` it to the
    # step's stdout so `score` (stdin: $pick.stdout) still receives the exact
    # bytes. Using `cmd > FILE && cat FILE` (NOT `cmd | tee FILE`) is
    # deliberate: a pipe-to-tee would mask a pick-credits.sh failure (under
    # POSIX sh there is no pipefail and the pipeline would take tee's exit
    # status), silently feeding score an empty/partial batch. With `&&`,
    # pick's non-zero exit short-circuits cat and propagates, so a failed
    # fetch still aborts the whole pipeline exactly as it did before this step
    # existed. The file path is the SAME ${raw_batch_file} arg interpolated
    # into CV_FRAUD_RAW_BATCH above, so the writer and the reader can never
    # disagree — and a per-run unique value (passed by dispatch-cv-batch.sh)
    # makes the handoff race-free across overlapping runs.
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/pick-credits.sh ${batch_size} ${selector_kind} ${selector_id} > ${raw_batch_file} && cat ${raw_batch_file}

  - id: score
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/score-backend-signals.sh
    stdin: $pick.stdout

  # mb_lookup step removed 2026-05-18: it contributed 0 mb_confirmed
  # approvals on the prior real-apply run while consuming ~8 of 11 min
  # wall-clock. signal_review credits now route directly to UVN via
  # verdict-engine. The MB scripts (run-mb-batch.sh, musicbrainz-isrc-
  # lookup.sh) remain on disk for ad-hoc debugging.

  # fraud step (2026-06-08): multi-factor PROFILE-level fraud detector. Runs
  # AFTER score, BEFORE verdict. stdin = scored buckets ($score.stdout);
  # raw batch re-read from CV_FRAUD_RAW_BATCH (teed by the pick step above).
  # off (default) = byte pass-through; shadow = annotate only; enforce =
  # downgrade signal_approve→signal_fraud (UVN). See spec §1-2, §8.
  - id: fraud
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/score-fraud-signals.sh
    stdin: $score.stdout

  - id: verdict
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/verdict-engine.sh
    stdin: $fraud.stdout

  - id: apply
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/apply-verdicts.sh ${dry_run}
    stdin: $verdict.stdout

  - id: summary
    command: /opt/hydra/workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/render-dry-run-summary.sh
    stdin: $apply.stdout
    env:
      THREAD_TS: ${thread_ts}
      # When THREAD_TS is empty (cron path), post the summary as a top-level
      # parent message in #credit-verification rather than dropping it.
      # See hydra#305 — without this the cron-fired runs left users with
      # only the agent's "Credit verification batch is running." placeholder.
      POST_PARENT_TO_CHANNEL: "1"
