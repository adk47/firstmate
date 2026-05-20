# Profile dedup detector

Read-only CLI that finds duplicate-profile candidates using deterministic
profile-level identifiers (Muso raw_profile_ids and IPIs).

Spec: `docs/superpowers/specs/2026-05-18-profile-dedup-detector-design.md`

## Usage

    bash scripts/dedup/find-dupes.sh --profile <uuid>
    bash scripts/dedup/find-dupes.sh --email   <addr>
    bash scripts/dedup/find-dupes.sh --catalog [--limit N]

Output: JSONL on stdout, one detected pair per line.

Requires `MUSO_ADMIN_EMAIL`+`MUSO_ADMIN_PASSWORD` (consumed by
`skills-all/muso-ops-admin/scripts/muso-admin-api.sh`, which caches the JWT
to a local file), `MUSO_API_URL`, and Trino access via
`scripts/trino-query.sh`. On hydra these all come from the gateway service
env.

Override paths via env if non-default locations apply:

    MUSO_ADMIN_API=/opt/hydra/skills-all/muso-ops-admin/scripts/muso-admin-api.sh
    TRINO_QUERY=/opt/hydra/scripts/trino-query.sh
    TIER2_ENDPOINTS_PATH=/opt/hydra/workspaces/operations/skills/muso-ops-admin/config/tier2-endpoints.txt

## Validation runs

### 2026-05-19 — Ali Zain ClickUp case (motivating example)

`--profile` against the verified Ali Zain:

    bash scripts/dedup/find-dupes.sh --profile d9840461-d027-42ed-8252-77fadbf35153

Result: `profile d9840461-d027-42ed-8252-77fadbf35153 has no profile-level
external identifiers; no hard match possible` on stderr. (The profile has 4
`raw_profile_ids` in matvw but no OTHER catalog profile shares any of them.)

`--email` against the customer:

    bash scripts/dedup/find-dupes.sh --email alionbeats644@gmail.com

Same stderr line. The customer's processed claim is
`09a8ad7f-00a5-44b1-9f06-d698bc8c79b7` (a different profile), NOT the
verified Ali Zain. Their rejected claim history on `d9840461-…` shows
they tried to claim the verified profile and got denied. The
"merge two Ali Zain profiles" request is asking us to consolidate
credits — but the two profiles share no external IDs.

Conclusion: **ID-less dupe per spec §11.** Same name and overlapping
credits, but no `raw_profile_ids` / `ipis` overlap. Out of v1 scope —
needs human review (Yann's manual merge UI) or a future name + credit
similarity extension.

### 2026-05-19 — Small catalog sample

    bash scripts/dedup/find-dupes.sh --catalog --limit 3

First cluster surfaced: many profiles all named "Empire" sharing
`tidal:34061432`, all unclaimed. The first 30 pairs of that cluster all
emit `verdict: "hard_dupe"` with that one Tidal raw_id. End-to-end SQL +
CSV parse + scoring path works against real Trino data.

This is also a great test case for the spec §11 risk "same external ID,
different humans" — multiple "Empire" profiles legitimately exist
(record labels, band, individual artist), so this cluster needs human
review before any auto-merge.

## Implementation notes

See the design spec §5.1 / §5.3 for the live shape of the admin API and
Trino columns. The 2026-05-19 commit `5a2c525` ("align with real admin API
+ Trino shapes after hydra validation") consolidates the seven plan-vs-
reality fixes discovered during first-run validation; check that commit
for the historical detail.

## What the detector can and can't do on the current backlog

End-to-end validation against the 27 profile-merge tickets in ClickUp list
901000600160 (2026-05-19, post-candidate_dupe-widening commit):

| Bucket | Count | Action |
|---|---:|---|
| Already merged (action_log confirms) — `sweeps/close-merged-tickets.sh --apply` closes them | 15 / 27 | Run sweep |
| `candidate_dupe` via `--pair` — customer named both UUIDs in `details` | 1 / 27 | Tier-2 review then merge |
| Prose-only — customer described duplicate by NAME, no UUID extractable | 9 / 27 | Manual lookup (current ops process) until a name-resolver lands |
| Null `customer_profile_id` (Caroline didn't capture) | 2 / 27 | Capture fix prevents future cases; existing 2 need manual ops |

The "prose-only" 9 are blocked on a name→UUID resolver step that doesn't
exist in this PR. They are not undetectable in principle — running
`admin GET /admin/profile/search?query=<name>` then `--pair` against each
candidate would catch them. That's a follow-on workstream.

The Caroline capture fix in `plugins/support-tools/src/tools/create-ticket.ts`
prevents new tickets from joining the prose-only bucket: any new
profile-merge AR is refused if `customerProfileId`,
`details.main_profile_url`, or `details.duplicate_profile_urls[]` is
missing or empty.

## Catalog scan landscape (2026-05-19)

`--catalog --limit 100` produced 422 hard_dupe pairs **all in one cluster**:
`tidal:34061432`, 30 unclaimed profiles all named "Empire". Either a real
cleanup opportunity (one Tidal artist, 30 Muso dupes) OR an upstream Tidal
data error (many different artists named "Empire" all linked to one Tidal
entry). Spec §11 risk #3 covers this case — human review required before
any merge action. We have not yet sized the rest of the catalog landscape
beyond the first cluster.

## Verification (2026-05-20)

Three parallel read-only audits to answer "does the detector report the
truth and find what humans would call duplicates?"

| Audit | Result | Notes |
|---|---|---|
| **Math correctness** | ✅ 5/5 pairs verified across 3 independent Trino views | Detector reports what's actually in the catalog. Minor credit-count discrepancies traced to matvw refresh lag, not detector logic. |
| **Recall** | ✅ measured: 20.2% shipped + 17.8% one-upgrade-away | `scripts/dedup/backtest/recall.py` against 258 real human merges over 90d. Detector-as-shipped catches **20.2%** (combined `hard_dupe` + `candidate_dupe`, reported as `recall_any` by `recall.py`); another **17.8%** sit in `soft_partial` (same-name, no credit asymmetry — would graduate if `shared_tracks ≥ 3` were a hard signal). Remaining 62% is stage-name ↔ legal-name (e.g. `AJJ2Clip ↔ Joseph Turner`) — structurally invisible without cross-name fuzzy or customer testimony. The earlier "unmeasurable retroactively" claim was wrong: admin-API aliasing hides loser UUIDs but `matvw_catalog_profile` preserves both sides post-merge, so backtest IS possible via raw_id/IPI subtraction. |
| **Precision** (20-pair sample, size-2 hard_dupe clusters) | ~95% LOW or MEDIUM-could-be-real, 1 confirmed HIGH-FP | Same-name + same-Jaxsta-ID + different-language tracks (`Maui` ES vs PT-BR sharing `jaxsta:163bd861-…`). Track-overlap signal would catch this. |

Soft-signal gap found: `country` populated on only 3/40 sampled profiles;
`primary_genre` blank on all 40. The detector's `country_match` soft
signal is effectively a no-op against current matvw data. A
`primary_genre_match` candidate signal was not implemented because the
underlying column is blank in the sample (it would be a no-op too).
Track-overlap (`shared_track_ids_count`) is the strongest discriminator
available but is currently only a soft signal, not a hard-signal upgrade.

Catalog scale: 67,237 size-2 name clusters; ~93k mergeable pairs total;
11 clusters at size ≥31 (Empire-style, require human triage).

## Core-backend handoff

Long-term home for this algorithm is `core-backend`. This CLI is the
research artifact, not the production path.

Spec for the algorithm itself: `docs/superpowers/specs/2026-05-18-profile-dedup-detector-design.md`.

Recall is already known from `backtest/recall.py` (20% shipped + 18%
upgrade-away + 62% structural ceiling). What backtest CAN'T give is
precision-on-the-live-queue, since `action_log` only records merges
humans approved. **Shadow-advisor mode** in `core-backend` (run detector
verdict next to every `/admin/profiles/merge` write, log both) closes
that gap by surfacing the verdict's behaviour on the population humans
*rejected* — the false-positive side. 1–2 weeks of real traffic →
confusion matrix.

Two tuning items already prioritised by the backtest:

1. **Upgrade `shared_track_ids_count ≥ 3` to a hard-signal rule.**
   17.8% of real merges are `soft_partial` (same-name, no credit
   asymmetry) — the detector won't promote them today. Track-overlap
   would catch most. Highest-leverage tuning item.
2. **Cross-name fuzzy / customer testimony path.** 62% of real merges
   are stage-name ↔ legal-name and structurally invisible to any
   name-keyed detector. The `--name` mode + `notify-merged-customers`
   + Caroline capture-fix in this PR are the human-loop coverage for
   this band; no algorithmic upgrade closes it.
3. **Restrict auto-action to cluster-size == 2.** Trivial config knob;
   ship alongside whatever auto-merge surface core-backend exposes.
