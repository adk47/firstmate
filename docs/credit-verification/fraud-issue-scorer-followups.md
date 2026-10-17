# CV fraud scorer follow-ups

Follow-up work deferred out of the Phase-1 multi-factor fraud detector
(`docs/credit-verification/fraud-detection-spec.md`,
`scripts/lobster-mvp/score-fraud-signals.sh`). None of these block the off →
shadow → enforce rollout; they harden and extend the detector once it is live.

## 1. Pre-compute the muso-only Trino factor as a daily materialized lookup

Today the `muso_only` factor calls Trino **in-loop** per batch via
`scripts/lib/fraud-muso-only-lookup.sh` (fail-soft: timeout/error → factor
weight 0, batch continues, run summary states the signal was unavailable). This
is correct but couples each batch run to live Trino latency/availability.

**Proposal**: materialize
`skills-all/muso-query-writer/saved-queries/misc/potential_fraud_accounts_muso_only_credits.sql`
into a daily snapshot table (or a small daily cron that writes a profile_id →
muso_only_pct lookup file), and have `fraud-muso-only-lookup.sh` read the
snapshot first, falling back to the live query only on cache miss/staleness.

- Keeps the fail-soft semantics (missing snapshot ⇒ live query ⇒ `{}` ⇒ weight
  0).
- Removes per-batch Trino dependency from the hot path.
- Decision tree mechanism: a **wall-clock daily refresh, no human in the loop**
  ⇒ openclaw cron in `cron-jobs.json` (per CLAUDE.md extension-picker), writing
  the snapshot; the helper just reads it.

## 2. Add collaborator / label-overlap factors (Tier-0 G7/G8) + account-age

The Phase-1 detector only uses factors derivable from the batch's per-credit
fields. Several proven Tier-0 / investigator signals need an **extra data
fetch** and were deferred:

- **Collaborator overlap (G7)** — does the claimed track's artist roster
  actually intersect this profile's established collaborators? Low overlap is a
  fraud tell (e.g. "Vrancis" 18% artist overlap). Needs a per-track artist
  lookup beyond `spotifyTrackArtists`.
- **Label overlap (G8)** — `metadata.label` vs the profile's historical labels.
- **Account age** — investigator scores new account `<30d` as `+2`. The batch
  JSON has `createdAt` on the credit but not a reliable profile-creation date;
  needs a profile-age fetch.

Each becomes a new weighted factor in the spec's §6 table with its own
`CV_FRAUD_W_*` env weight, defaulting to a weight that keeps the existing
0.60 flag line stable (re-document the default-score sanity math in the spec).

## 3. Backtest thresholds against a labeled set

`CV_FRAUD_THRESHOLD` (0.60) and the per-factor weights are grounded in the
Tier-0 gates and the investigator point system, **not** yet validated against
labeled outcomes.

- Assemble a labeled set: the named fraud accounts (Ming Vauz, Roberto Junior,
  Vrancis, Javon) as positives, plus a sample of confirmed-legit established
  profiles as negatives.
- Run the scorer in `shadow` mode over a historical batch window and compute
  precision/recall at a sweep of thresholds/weights.
- Pick the operating point that maximizes recall on known fraud while keeping
  false-positive UVN load tolerable for the (currently constrained) CS team.
- Record the chosen thresholds + the backtest in the spec's lessons/changelog.
- This pairs with the durable `fraud_signals` table
  (`fraud-issue-db-state.md`, Option B) which gives the queryable history the
  backtest needs.

## 4. Consider applying fraud detection to Caroline's customer-facing path

**Explicitly out of scope for Phase 1** (operations batch only). Before any
Caroline wiring:

- Caroline must **never auto-approve** a fraud-flagged credit. A fraud flag on
  the customer-facing path routes to a **flagged security-review ticket**, not
  to an automated grant or rejection — mirroring the existing
  never-reject / ask-once posture and the customer-credit-verification
  red-team rule (no autonomous approve on private proof).
- Reuse the same profile-level scorer and reason string so operations and
  Caroline share one explainable verdict format.
- This is a separate, gated rollout (its own flag, its own review ticket type)
  and should be scoped as its own issue once the operations path is proven in
  `enforce`.

## 5. Hardening punch-list (deferred from the build review)

Lower-risk items the adversarial review surfaced, intentionally deferred so they
don't expand the flag-off MVP:

- **Profile-relative breadth (true Tier-0 G5).** `role_inflation` currently uses
  an *absolute* `CV_FRAUD_ROLE_BREADTH_MAX` (default 6). The real G5 is relative
  (`max(unverified breadth) > max(approved breadth)+1`, the "Sam Feldt fix" for
  legit multi-role artists) and needs the profile's approved corpus, which the
  per-credit batch object doesn't carry. Fold this in alongside the G7/G8 fetch
  in item 2.
- **`Sound Design` whole-word edge.** Role matching is now whole-word (`\bart\b`
  no longer matches "Quartet"), but `\bdesign\b` still matches "Sound Design"
  (arguably a creative role). Add an allowlist/exception or a richer role
  taxonomy if shadow backtesting shows false positives.
- ~~**Run-scope the raw-batch temp file.**~~ DONE (QA round 2): the path is now
  the `raw_batch_file` pipeline arg, interpolated into both the pick command and
  the fraud step's `CV_FRAUD_RAW_BATCH`; `dispatch-cv-batch.sh` passes a unique
  `/tmp/cv-fraud-raw-batch.<pid>.<epoch>.json` per run and cleans it up on exit.
- ~~**Verify lobster step-env merge semantics on node-8.**~~ DONE (2026-06-10):
  verified live against the deployed `@clawdbot/lobster` with a throwaway
  pipeline — pipeline-level `env:` MERGES into a step that declares its own
  `env:` block (and `${arg}` interpolation works in both). No change needed for
  the summary step.

## Acceptance criteria

- [ ] Muso-only factor reads from a daily materialized snapshot with live-query
      fallback; fail-soft semantics preserved (batch never blocks on Trino).
- [ ] At least one of collaborator-overlap / label-overlap / account-age added
      as a weighted factor with its own `CV_FRAUD_W_*` env and updated
      default-score math in the spec.
- [ ] A reproducible backtest (shadow over a historical window) with a labeled
      positive/negative set produces precision/recall at the chosen operating
      point, recorded in the spec.
- [ ] A separate, explicitly-gated issue exists for the Caroline customer-facing
      path with the never-auto-approve / security-review-ticket constraint
      written into its acceptance criteria.
- [ ] All new env vars documented in the spec's §7 table with defaults.

## Suggested labels

`enhancement`, `P2` (observability / hardening). Use `chore` + `P3` for the
materialized-lookup refactor if split out as its own card; the Caroline
follow-up, when filed, should carry `P0`/`P1` given it touches the
customer-trust surface.
