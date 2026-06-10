# Persist credit fraud-state in core-backend (durable DB)

## Context

The hydra batch credit-verification pipeline now has a multi-factor **fraud
detector** (`workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/score-fraud-signals.sh`,
spec: `docs/credit-verification/fraud-detection-spec.md`). In `enforce` mode it
downgrades a credit the backend would auto-approve to
`status = user_verification_needed` (UVN) and carries an explainable reason
string of the form `fraud:role_inflation+source_quality+...=0.80`.

**The problem**: today that fraud verdict has **nowhere durable to live in the
DB.** It rides entirely on:

- `credit_requests.status = "user_verification_needed"` — which is overloaded
  (it is also the destination for backend hard-rejects, name mismatches,
  popularity anomalies, no-Tier-1-match, metadata-inconsistent, etc.). You
  cannot tell from the row *why* it is in UVN, or that fraud was the cause.
- The hydra-side `flag_reason` value `fraud_multifactor` (closed-list enum,
  forwarded by `batch-flag-credits.sh` via `OPS_FLAG_REASON`) — but the
  human-readable factor breakdown and the normalized 0..1 fraud score are only
  written to the **hydra run log + Slack summary**, never to Postgres.

So the fraud signal is not queryable post-hoc: an analyst cannot run
"show me every credit flagged for fraud last week, with which factors fired and
the score" against the DB. There is **no dedicated fraud status, column, or
audit table.**

## Stack

- core-backend: **Node / Express / Sequelize / Postgres**
- Migrations: **sequelize-cli** migrations, target branch **`develop`**
- Risk scoring today is produced **externally** by `industry-data-processing`
  and lands in the credit request's `verificationData` blob
  (`total_risk_percent`, `rule_risk_percent.*`). The hydra fraud detector is a
  **second, separate** scorer layered on top of that — its output is not yet
  ingested by core-backend at all.

## Proposed change (pick one of A or B in design review)

### Option A — columns on `credit_requests` (lighter, denormalized)

Add to `credit_requests` via a sequelize-cli migration:

- `fraud_flag BOOLEAN NOT NULL DEFAULT false` — set when the hydra scorer
  flags `over == true`.
- `fraud_score NUMERIC(4,3) NULL` — the normalized 0..1 score
  (`_fraud.score`).
- `fraud_reasons JSONB NULL` — the `_fraud.fired` array + `_fraud.reason`
  string (and optionally the per-factor `_fraud.factors` map) so the breakdown
  is queryable.

Pros: trivial to join/filter; one row per credit. Cons: only stores the
*latest* fraud verdict, no history if re-scored.

### Option B — dedicated `fraud_signals` audit table (normalized, historical)

```
fraud_signals (
  id              uuid pk,
  credit_request_id uuid fk -> credit_requests.id,
  profile_id      uuid,
  fraud_score     numeric(4,3),
  over_threshold  boolean,
  factors         jsonb,        -- {role_inflation:0.2, source_quality:0.133, ...}
  fired           text[],       -- ["role_inflation","source_quality",...]
  reason          text,         -- "fraud:role_inflation+...=0.80"
  muso_only_available boolean,
  muso_only_pct   numeric,
  orig_bucket     text,         -- signal_approve | signal_review | signal_uvn
  detector_version text,
  created_at      timestamptz
)
```

Pros: append-only audit trail, supports re-scoring and threshold backtests
without losing prior verdicts; keeps `credit_requests` clean. Cons: extra join.

**Recommendation**: Option B. The fraud detector's whole value is explainability
and the ability to backtest thresholds against a labeled set
(`fraud-issue-scorer-followups.md`), which an append-only table supports and a
single mutable column does not.

### New status / boolean

The DB UVN status is overloaded. Either:

- add a **boolean** `fraud_flag` (Option A) / derive it from `fraud_signals`
  (Option B), OR
- add a new enumerated status value (e.g. `fraud_review`) **only if** the
  product/Caroline UX is ready to treat it distinctly. Defer the new status
  unless there is a consumer for it — a boolean + reason is enough to
  un-overload UVN for analytics today.

### Slack / event hooks

- Emit a domain event (e.g. `credit.fraud_flagged`) when a `fraud_signals` row
  with `over_threshold = true` is written, so downstream consumers (Slack
  alerting, an internal review queue) can subscribe without polling.
- Keep the existing hydra Slack FRAUD section as the operator-facing surface;
  the backend event is the durable/structured counterpart.

### Wiring the hydra scorer's reason string in

- The hydra `apply-verdicts.sh` / `batch-flag-credits.sh` path already POSTs to
  the admin API with `flag_reason = fraud_multifactor` and a human reason.
- Extend that admin endpoint (or add a new one) to accept the structured
  `_fraud` object (`score`, `factors`, `fired`, `reason`, `muso_only_*`,
  `orig_bucket`) and persist it to the chosen schema above.
- Add `fraud_multifactor` to the backend's `flag_reason` enum so the categorical
  value validates server-side (hydra already enforces it in
  `FLAG_REASONS_REGEX`).

## Acceptance criteria

- [ ] A sequelize-cli migration on `develop` adds the chosen schema (Option A
      columns or Option B `fraud_signals` table), with a reversible `down`.
- [ ] The admin credit-flag endpoint accepts and persists the structured
      `_fraud` payload (score, fired factors, reason string, muso_only
      availability, orig_bucket).
- [ ] `flag_reason = fraud_multifactor` validates server-side (enum updated).
- [ ] A query "all fraud-flagged credits in a window with score + fired factors"
      is answerable directly from Postgres (no run-log scraping).
- [ ] A `credit.fraud_flagged` event (or equivalent) fires on persist of an
      over-threshold verdict.
- [ ] Re-running the hydra batch in `enforce` mode against staging produces rows
      in the new schema that match the Slack FRAUD section for the same run.
- [ ] No regression to the existing UVN path for non-fraud flag reasons.

## Suggested labels

`enhancement`, `P2` (note: hydra has **no `tech-debt` label** — use `chore` for
non-feature maintenance; this is feature-ish so `enhancement` + `P2`).
