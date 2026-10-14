# Batch Fraud Detection — Authoritative Spec

> **Version**: 1.0 (Phase 1 foundation) | **Date**: 2026-06-08
> **Scope**: operations credit-verification **BATCH** pipeline ONLY.
> Caroline / customer-facing credit verification is **OUT OF SCOPE**.
>
> This document is the contract. Downstream Phase-2/3 work (verdict-engine,
> lobster wiring, Slack, flag-reasons, tests) implements **strictly** against
> the shapes, env vars, and semantics defined here. If code and this doc
> disagree, that is a bug in one of them — reconcile, don't guess.

Read [design.md](./design.md) (Tier-0 gates) and the
`muso-credit-investigator` SKILL (point system) first; this detector is the
**inverse** of the Tier-0 establishment gates plus the investigator's
role-inflation heuristics, packaged as a profile-level batch step.

---

## 1. Where it sits

```
pick-credits.sh  →  score-backend-signals.sh  →  [score-fraud-signals.sh]  →  verdict-engine.sh  →  apply-verdicts.sh  →  render-*-summary.sh
                    (signal_approve/review/uvn)   NEW Phase-1 step             (Phase-2: maps
                                                                                signal_fraud→would_uvn)
```

`score-fraud-signals.sh` is a **profile-level** detector: it aggregates the
batch's credits by `profileId`, computes per-profile factor scores once, then
stamps each credit. It can **downgrade a backend `signal_approve` to a new
`signal_fraud` bucket**, so a credit the backend would auto-approve is instead
routed to UVN. It never auto-rejects.

## 2. Three modes (`CV_FRAUD_MODE`)

Mirrors the proven `CV_EVIDENCE_MODE` flag-off rollout pattern.

| Mode | Behavior |
|---|---|
| `off` *(default)* | Pure pass-through. Stdin emitted **unchanged**. No Trino call, no `_fraud`, no `signal_fraud`. The step is a no-op. |
| `shadow` | Compute fraud, stamp `_fraud` on every credit, and add a top-level `signal_fraud` array of **copies** of over-threshold credits (with `_fraud.orig_bucket` set). **`_signal.bucket` is NOT changed** — verdicts are identical to a no-fraud run. Surfaces in Slack only. |
| `enforce` | Compute fraud; for every credit with `_fraud.over == true`, set `_signal.bucket = "signal_fraud"` (overriding `signal_approve`/`signal_review`/`signal_uvn`), record `_fraud.orig_bucket`, and **move** the credit into the top-level `signal_fraud` array. `signal_approve` shrinks accordingly. |

> **Rollout safety**: `enforce` requires the Phase-2 `verdict-engine.sh` change
> (it must map `signal_fraud → would_uvn`, otherwise a `signal_fraud` credit is
> silently dropped — the pre-Phase-2 verdict-engine only read
> `signal_approve`/`review`/`uvn`). Phase-2 shipped together with this scorer
> (same branch), so all three modes are safe once this version deploys. Roll
> out `off → shadow → enforce` regardless: run at least one shadow batch and
> review Slack + the results truth floor before flipping enforce.

## 3. Input contract

**Stdin** — the exact stdout of `score-backend-signals.sh`:

```json
{ "queue_depth": 2, "fetch_size": 500, "selector": null,
  "counts": {"total":2,"signal_approve":2,"signal_review":0,"signal_uvn":0},
  "signal_approve": [
    {"cr_id":"cr-1","profile_id":"<uuid>","isrc":"US1","credited_name":"Ming Vauz","role":"Editorial",
     "_signal":{"bucket":"signal_approve","reason":"validator_approved,risk=10","validator_approved":true,"total_risk_percent":10}}
  ],
  "signal_review": [], "signal_uvn": [] }
```

**Env `CV_FRAUD_RAW_BATCH`** — path to a file containing the **raw fetched
batch** (stdout of `pick-credits.sh` / `fetch-*.sh`):

```json
{ "queue_depth": 2,
  "items": [
    {"id":"cr-1","profileId":"<uuid>","credits":["Editorial"],
     "metadata":{"source":"spclient","label":"X","isrc":"US1"},
     "profile":{"creditCount":34,"popularity":5,"name":"Ming Vauz"},
     "verificationData":{"is_approved":true,"total_risk_percent":10,
       "rule_risk_percent":{"approve_owning_track":0,"reject_high_velocity_profile":0}}},
    ...
  ] }
```

The scorer needs the raw fields (`credits[]`, `metadata.source/label`,
`profile.creditCount/popularity`, `verificationData.rule_risk_percent`) that
`score-backend-signals.sh` drops. Credits are joined on
`items[].id == per-credit .cr_id`. Profile factors are keyed on
`items[].profileId == per-credit .profile_id`.

### Why a file (and why this is least-invasive)

A Lobster step has exactly one stdin, which must be the scored buckets so the
**output is a drop-in superset** of `score-backend-signals.sh`'s output (off/
shadow runs are byte-identical at the bucket level). Re-reading the raw batch
from a file modifies **no existing script** — `pick-credits.sh`,
`score-backend-signals.sh`, and `verdict-engine.sh` stay byte-for-byte
unchanged. **Phase-2 is responsible for persisting `$pick.stdout` to this
file** and exporting `CV_FRAUD_RAW_BATCH`; see §8.

### Fail-soft on missing/invalid raw batch

If `CV_FRAUD_RAW_BATCH` is unset, unreadable, or has no `.items` array, the
scorer **fails soft to pure pass-through** (stdin emitted unchanged, loud
stderr note), regardless of mode. The batch is never blocked.

## 4. Output contract

Same top-level shape as the input, plus:

* **Every per-credit object gains `_fraud`** (in shadow and enforce; never in
  off):

  ```json
  "_fraud": {
    "score": 0.8,
    "threshold": 0.60,
    "over": true,
    "factors": { "role_inflation":0.2, "source_quality":0.133, "establishment":0.133,
                 "velocity":0.133, "backend_hard_reject":0, "muso_only":0.2 },
    "fired": ["role_inflation","source_quality","establishment","velocity","muso_only"],
    "reason": "fraud:role_inflation+source_quality+establishment+velocity+muso_only=0.8",
    "muso_only_available": true,
    "muso_only_pct": 80.0,
    "orig_bucket": "signal_approve"
  }
  ```

  `factors` values are each factor's **weighted, normalized contribution**
  (weight / total-weight) when fired, else 0. `reason` is `null` when
  `over == false`. `orig_bucket` is present only on credits in `signal_fraud`.

* **`shadow`**: existing `signal_*` arrays unchanged; new
  `signal_fraud` = copies of over-threshold credits;
  `counts.signal_fraud` added.

* **`enforce`**: over-threshold credits moved into `signal_fraud` with
  `_signal.bucket="signal_fraud"` and `_signal.reason = _fraud.reason`;
  `counts.signal_approve/review/uvn` recomputed; `counts.signal_fraud` added.

### Real example output line (enforce, credit cr-1, abridged)

```json
{"queue_depth":2,"fetch_size":500,"selector":null,
 "counts":{"total":2,"signal_approve":1,"signal_review":0,"signal_uvn":0,"signal_fraud":1},
 "signal_approve":[{"cr_id":"cr-2",...,"_fraud":{"score":0,"over":false,"fired":[],"reason":null,...}}],
 "signal_review":[],"signal_uvn":[],
 "signal_fraud":[{"cr_id":"cr-1","profile_id":"<uuid>","isrc":"US1","credited_name":"Ming Vauz","role":"Editorial",
   "_signal":{"bucket":"signal_fraud","reason":"fraud:role_inflation+source_quality+establishment+velocity+muso_only=0.8"},
   "_fraud":{"score":0.8,"threshold":0.60,"over":true,
     "factors":{"role_inflation":0.2,"source_quality":0.133,"establishment":0.133,"velocity":0.133,"backend_hard_reject":0,"muso_only":0.2},
     "fired":["role_inflation","source_quality","establishment","velocity","muso_only"],
     "reason":"fraud:role_inflation+source_quality+establishment+velocity+muso_only=0.8",
     "muso_only_available":true,"muso_only_pct":80.0,"orig_bucket":"signal_approve"}}]}
```

## 5. Reason-string format (authoritative)

```
fraud:<factor1>+<factor2>+...+<factorN>=<score>
```

* `<factorK>` are the **fired** factor names, in this fixed order:
  `role_inflation`, `source_quality`, `establishment`, `velocity`,
  `backend_hard_reject`, `muso_only` (only those that fired are listed).
* `<score>` is the normalized 0..1 score rounded to 2 decimals
  (e.g. `0.8`, `0.73`).
* Produced only when `over == true`; otherwise `_fraud.reason` is `null`.

This string is carried on `_signal.reason` (enforce) and `_fraud.reason`
(both modes) so Slack and the audit trail are explainable.

## 6. Factors & score

Computed **per profile** over that profile's credits in the current batch.
Each factor is a 0/1 indicator. The score is the weighted sum of fired factors
**divided by the sum of all weights**, so `score ∈ [0,1]` and the threshold is
unit-free and stable across weight retunes.

```
score = Σ(weight_f · fired_f) / Σ(weight_f)        for f in {role_inflation, ...}
over  = score ≥ CV_FRAUD_THRESHOLD
```

| Factor | Fires when | Grounding |
|---|---|---|
| `role_inflation` | non-creative-role fraction across the profile's batch roles ≥ `CV_FRAUD_ROLE_INFLATION_FRAC` **OR** max roles-per-track breadth ≥ `CV_FRAUD_ROLE_BREADTH_MAX` | investigator non-creative list; absolute "11-role bundle" breadth (NOT the profile-relative Tier-0 G5 — relative-G5 is a deferred follow-up); "Javon"/"Ming Vauz" patterns |
| `source_quality` | fraction of credits with `metadata.source != "industry"` > `(1 − CV_TIER0_MIN_INDUSTRY)` (i.e. spclient-heavy) | Tier-0 G3 inverse; "Roberto Junior" (84% spclient) |
| `establishment` | `profile.creditCount < CV_TIER0_MIN_CC` **OR** `profile.popularity < CV_TIER0_MIN_POP` | Tier-0 G1/G2 inverse; "Ming Vauz" (cc=34) |
| `velocity` | any credit's `verificationData.rule_risk_percent.reject_high_velocity_profile > 0` | since 2026-10-11 score-backend also routes such a credit to `signal_uvn` (any `reject_*` > 0) |
| `backend_hard_reject` | any of the 5 `reject_*` signals > 0 (artist / deleted_catalog_track / individual_org / publisher_label / high_risk_profile) | already-known fraud-ish; score-backend now sends ANY `reject_*` / `review_*` rule > 0 to `signal_uvn` (a superset of these 5) |
| `muso_only` | profile's muso-only popularity fraction > `CV_FRAUD_MUSO_ONLY_PCT`, **and the Trino lookup succeeded** | `potential_fraud_accounts_muso_only_credits.sql` |

**Non-creative role list** (case-insensitive, **whole-word** match — `\bart\b`
matches "Cover Art" but NOT "Quartet"/"Artwork"; multi-word entries like "album
cover" still match within "Album Cover Photography"):
`Album Cover, Editorial, Photography, Art, Design, A&R, Marketing,
Management, Publisher`.

### `muso_only` fail-soft

The `muso_only` factor is the **only** Trino-backed factor and is fail-soft.
`fraud-muso-only-lookup.sh` returns a wrapper `{available: <bool>, data:
{<pid>:<pct>}}`. **`available` is the source of truth** — the scorer reads it,
never inferring "down" from an empty `data` map. A healthy Trino that returns
zero qualifying rows (the common clean case) is `available:true, data:{}`; only
a genuine failure (timeout, error, no pod, parse failure, or a non-empty body
that yields zero parseable rows — e.g. an HTML error page) is
`available:false`. On `available:false` the factor contributes **0** for the
whole batch, `_fraud.muso_only_available = false`, and the run summary states
loudly that the muso-only signal was unavailable this run. The batch is
**never** blocked on Trino.

## 7. Env-var table (authoritative)

| Env var | Default | Meaning |
|---|---|---|
| `CV_FRAUD_MODE` | `off` | `off` (no-op pass-through) \| `shadow` (annotate, keep verdicts) \| `enforce` (override approve→fraud). Unknown value → treated as `off` with a warning. |
| `CV_FRAUD_RAW_BATCH` | *(unset)* | Path to the raw fetched-batch JSON file (`{items:[...]}`). Required for shadow/enforce; missing → fail-soft pass-through. |
| `CV_FRAUD_THRESHOLD` | `0.60` | Normalized score (0..1) at/above which a profile's credits are flagged. |
| `CV_FRAUD_W_ROLE_INFLATION` | `3` | Weight of the role_inflation factor (investigator: non-creative role on pop track = +3). |
| `CV_FRAUD_W_SOURCE_QUALITY` | `2` | Weight of the source_quality factor. |
| `CV_FRAUD_W_ESTABLISHMENT` | `2` | Weight of the establishment factor (new-account/low-cc fraud = +2). |
| `CV_FRAUD_W_VELOCITY` | `2` | Weight of the velocity factor (same role on 5+ tracks/7d = +2). |
| `CV_FRAUD_W_BACKEND_HARD_REJECT` | `3` | Weight of the backend_hard_reject factor. |
| `CV_FRAUD_W_MUSO_ONLY` | `3` | Weight of the muso_only Trino factor. |
| `CV_FRAUD_ROLE_INFLATION_FRAC` | `0.50` | Non-creative-role fraction at/above which role_inflation fires. |
| `CV_FRAUD_ROLE_BREADTH_MAX` | `6` | Absolute max roles-per-track that also fires role_inflation (the "11-role bundle" pattern). NOT the relative Tier-0 G5. |
| `CV_FRAUD_MUSO_ONLY_PCT` | `50` | muso-only popularity percent above which muso_only fires (saved-query band). |
| `CV_TIER0_MIN_CC` | `100` | Establishment floor on `profile.creditCount` (Tier-0 G1). Shared with Tier-0. |
| `CV_TIER0_MIN_POP` | `50` | Establishment floor on `profile.popularity` (Tier-0 G2). Shared with Tier-0. |
| `CV_TIER0_MIN_INDUSTRY` | `0.70` | Min industry-source fraction (Tier-0 G3); source_quality fires below it. Shared with Tier-0. |

For the `fraud-muso-only-lookup.sh` helper:

| Env var | Default | Meaning |
|---|---|---|
| `CV_FRAUD_MUSO_TRINO_TIMEOUT` | `300` | Seconds; wall-clock cap on the Trino call via `timeout`. Expiry → `{"available":false,"data":{}}` + exit 0. (25→300 in the 2026-06-11 column fix: the live query measures 56–134s.) |
| `CV_FRAUD_MUSO_MIN_TRACK_POP` | `50` | `total_track_popularity` floor (denominator-sanity guard, mirrors the saved query's `> 50`). |
| `TRINO_QUERY_SH` | *(resolved)* | Override path to `scripts/trino-query.sh` (for tests). |

> **Default-score sanity**: with the defaults above, total weight = 15. A
> profile firing role_inflation(3)+source_quality(2)+establishment(2)+
> velocity(2) scores 9/15 = 0.60 ≥ threshold → flagged. Two factors alone
> (e.g. establishment+velocity = 4/15 = 0.27) do not. Tune `CV_FRAUD_THRESHOLD`
> or weights to move the line; the score is always comparable because it is
> weight-normalized.

## 8. Pipeline wiring (for the Phase-2 implementer)

Insert a `fraud` step in `verify-credit-batch-mvp.lobster` between `score` and
`verdict`, feeding the scored buckets on stdin and the raw batch via a file:

* Persist `$pick.stdout` to a temp file (e.g. a tiny wrapper, or a Lobster
  `env:`/`command:` interpolation that writes `$pick.stdout` to a path), and
  pass that path as `CV_FRAUD_RAW_BATCH`.
* `stdin: $score.stdout`; then `verdict`'s `stdin: $fraud.stdout`.
* Default `CV_FRAUD_MODE=off` in the pipeline `env:` so the step is a no-op
  until explicitly rolled forward to `shadow`, then `enforce`.

## 9. Deferred (DB schema — GH issues, not implemented in Phase 1)

The DB does not currently persist a structured fraud verdict alongside the
credit. Two schema changes are **deferred to [#454](https://github.com/Muso-AI/hydra/issues/454)**
(durable DB fraud-state); scorer enhancements are tracked in
[#455](https://github.com/Muso-AI/hydra/issues/455):

1. A `fraud_score` / `fraud_reason` column (or sidecar table) on
   `credit_requests` so the flag is queryable post-hoc, not only in run logs.
2. A closed-list `flag_reason` enum extension to carry `fraud_multifactor`
   (today's enum is `name_mismatch|popularity_anomaly|no_tier1_match|
   metadata_inconsistent`; see §10 note for the Phase-2 interim mapping).

Until then, the fraud verdict lives in the run log + Slack only.

## 10. Files (Phase 1)

* `workspaces/operations/skills/muso-ops-credit-verification/scripts/lobster-mvp/score-fraud-signals.sh` — the scorer.
* `workspaces/operations/skills/muso-ops-credit-verification/scripts/lib/fraud-muso-only-lookup.sh` — fail-soft batched Trino lookup.
* `docs/credit-verification/fraud-detection-spec.md` — this contract.
