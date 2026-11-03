# Verifier eval: one shadow scorecard for every credits / claims / merges verifier

**Status:** shadow harness, 2026-10-28 (verifier-eval-v1). Nothing here approves, declines, merges or
messages anyone. Whether a verifier acts live stays the captain's call; this is the measurement he reads.

## What it is

- **Frozen labelled sets**: `scripts/verifier_eval/sets/{credits,claims,merges}.jsonl.gz`, one item per
  credit request / claim / merge pair, each with a ground-truth `label` (APPROVE / DECLINE / WAIT),
  `known_bad`, `label_source`, `label_strength` (`human` / `audit` / `fable_handoff` /
  `ops_classification`), and the frozen `evidence` a verifier may read (same-run IDP
  `helpers.fresh_capture` per role per source, account gate, flags, validator record, claim features,
  merge facts). Ids, popularity, roles and verdict codes only: no names, e-mails, titles or document text.
- **Runner** (`scripts/verifier_eval/runner.py`): replays any verifier `fn(item) -> Verdict` or any
  recorded shadow log, writes an audit row per verdict (`verdicts.jsonl`, with the evidence sha), and
  scores it per class, **paid first**.
- **Independent guard** (`scripts/verifier_eval/protections.py`): every APPROVE is re-checked against
  the evidence whatever the label says: UNKNOWN never approves, account gate `allow`, popularity < 60,
  not watchlisted / IDP-held / validator fraud rule, credits need a same-run Spotify AND Tidal read with a
  CREDITED-by-linked-id anchor on every approved role (a name match never counts), claims need a bound
  proof (E1 / E3), merges need every owner-confirmed fact.
- **Adjudications** (`sets/adjudications.json`): disagreements checked against the evidence. Labels stay
  frozen; the report shows precision raw and after adjudicated label defects.

## Must be zero before a verifier goes to the captain

`false_approve` (approved a DECLINE-labelled or known-bad item), `approve_on_known_bad`,
`protection_violations`. Reported but not zero-gated: approve / decline precision and recall, approve on a
WAIT label, role over-approve, false decline, UNKNOWN count, evidence coverage.

## Run it

```
python3 scripts/verifier-eval.py list
python3 scripts/verifier-eval.py run --out ./ve-out                          # every registered verifier
python3 scripts/verifier-eval.py run --verifier credits:my.module:verdict   # an out-of-tree verifier
python3 scripts/verifier-eval.py run --verdicts claims:/path/shadow.jsonl   # a recorded shadow log
python3 scripts/verifier-eval.py build --data ~/Projects/firstmate/data      # rebuild the sets (Mac)
```

A shadow log is JSONL `{"id", "verdict", "approved_roles"?, "reasons"?}`; `verified`/`pass` read as
APPROVE, `contradicted`/`reject`/`fail` as DECLINE; unjudged items score UNKNOWN.

**Nightly** on node-8 (`/etc/cron.d/hydra-verifier-eval`, 04:40 UTC, installed by
`scripts/install-aux-units.sh`): every registered verifier plus every log dropped in
`/var/lib/hydra/verifier-eval/inbox/<set>/*.jsonl`. Output `/var/lib/hydra/verifier-eval/latest/`
(`board.txt` = the board line, `board.json` = P/R/FA/guard violations per verifier per class,
`report.md`, `metrics.json`, `verdicts.jsonl`), `history.jsonl` keeps every board line, 30 run dirs kept.
Kill switch: `touch /etc/hydra/verifier-eval.disabled`.

## Where the labels come from (2026-10-28 build)

| set | items | labels A / D / W | sources |
|---|---|---|---|
| credits | 3,578 (paid 1,019 / free 2,528) | 35 / 70 / 3,473 | d1 docs-on-file trays (p1 paid, p2 free) with full per-role same-run capture; d3 validator-declined trays (p3, request-level capture only); 48 credit-retro take-backs (human, known bad); fraud watchlist + chart-fraud T1 accounts |
| claims | 1,458 (paid 225 / free 1,233) | 0 / 17 / 1,441 | d2 claim trays over the c1/c2 packets (CRS score, code check, gate) |
| merges | 275 (71 pairs + 204 tickets) | 41 / 77 / 157 | m1 queue classes; m1 d1-batch re-check and shadow log; core `409 LOGIN_OR_PRIMARY_LOSER` (audit) |

Fable-handoff labels are as of the ruling; a later capture can make one stale (see adjudications). Not
yet in: documents (the doc-verify labelled set, BeatStars template family) belong to doc-verify's own
`eval` (build plan C8) and plug in here as a recorded log keyed by request id; historical Jan/Ops
approvals at scale need a replica export (`trino-query.sh`) with the evidence at decision time.

## First numbers (2026-10-28 ~07Z)

| verifier | class | approve | P | R | false-approve | guard violations | decline P / R |
|---|---|---|---|---|---|---|---|
| credits-rules-v1 (reference) | paid | 6 | 0.667 (1.000 adjudicated) | 0.50 | 0 | 0 | - |
| | free | 9 | 0.889 | 0.73 | 0 | 0 | 0 / 0 (5 d3-rule declines d1 left WAIT) |
| claims-rules-v1 (reference) | paid / free | 0 (no bound proof exists yet) | - | - | 0 | 0 | 0.50 / 1.0 · 0.77 / 0.81 |
| merges-rules-v1 (reference) | all | 2 | 1.000 | 0.05 (evidence on 29 %) | 0 | 0 | - |
| claims-crs-recorded (core scorer) | paid / free | 1 / 18 | 0 | - | 0 | **19** (`no_bound_proof`) | - |
| merges-cli-gate-recorded (muso-cli consolidate) | all | 35 | 0.06 | - | **29** | **33** (`login_or_primary_loser` 29) | - |
| credits-validator-recorded | free | 1 | 0 | - | 0 | **1** (`no_id_anchor`) | - |

Both name-match negative controls score NOT CLEAN (credits 1,106 guard violations, claims 781), which
is the proof the harness catches what the captain forbade.

## Merge replay agreement (self-serve precondition)

Every verifier's row carries a replay **agreement** with the labels over the whole set: `binary` (would it
act or not; an item it never judged counts as a disagreement, so full coverage is part of 100 %) and
`exact` (APPROVE / DECLINE / WAIT). For merges the labels are m1's queue classes, m1's re-check and
core's `409 LOGIN_OR_PRIMARY_LOSER` refusals, so the core verify endpoint's row is the self-serve
precondition: **binary 100 % and an empty disagreement list** (`board.json` lists every disagreement for
merges). Drop the endpoint's dry run as `/var/lib/hydra/verifier-eval/inbox/merges/<name>.jsonl`, one row
per item: `{"id": "<ticket>" | "<ticket>:<loser 8-hex>", "verdict": "eligible" | "refused:<slug>" |
"queued_review"}` (ids as in `sets/merges.jsonl.gz`). Baseline today: merges-rules-v1 71/275 (204 tickets
carry no facts), muso-cli gate 38/275.

### Independent re-label (2026-10-28 18:40Z) and the core verify endpoint

`scripts/verifier-eval-merge-facts.py` reads today's facts for all 275 items READ-ONLY (n19 replica,
`pg_is_in_recovery()` asserted, plus industry-api) with profiles taken from m1's own ticket file, never
from a verifier's output; `scripts/verifier_eval/merge_relabel.py` (pure) applies the written contract
(self-merge-1026 v1, Fable q1-merge-fable-1027 empty shell, core's 10-13 login/primary guard) and lands
on the side that does not act whenever evidence it does not read is needed. `verifier-eval.py
relabel-merges` writes the label variant `sets/merges@relabel-20261028`; every recorded log is scored
against the base set and every variant. b1's endpoint dry run is frozen in
`sets/recorded/merges/core-verify-b1-20261028.jsonl`.

Result: the 61 rows b1 attributed to stale labels agree 61/61 binary with the independent labels
(exact 53/61, all 8 are refusal-code order: MERGE_IN_PROGRESS / PRIMARY_PROFILE vs NOT_CLAIMED); core's
409 column matches on all 71 pairs. Over all 275: **272/275 on the sensitivity variant, precondition NOT
met.** The 3 are
`869dfc1q1:c8ade1ee`, `1amvh554wa7:f969085a`, `1amvh554ymh:cb464ea4`: the loser is the requester's own
login / presented primary, the main is held only by a SEAT claim (`claiming.userId` NULL) in the
requester's default workspace; the endpoint answers `eligible` (primary switch, then fold), the written
contract admits the switch only when the main is the caller's OWN processed claim -> `PRIMARY_PROFILE`.
The endpoint cites `isOwnLoginProfileClaim`, which in core covers a claim on the user's own LOGIN profile,
not any seat-claimed main.

### An unread safety gate is never `eligible` (2026-11-03)

`LEGAL_HOLD` is a real self-merge refusal slug (core `selfMerge/rules.js`, `docs/self-serve-profile-merge.md`):
staff put the profile on a search hold via `profile_search_visibility` with `source='staff'`. That table does
not exist on prod core - core's migration `20261002150000-create-profile-search-visibility.ts` is absent from
`_migrations`, so the auxiliary migration has never been deployed and core itself fails open on the absent
pre-migration table. The first facts snapshot therefore recorded `staff_hold_table_present: false` while the
relabel still answered `eligible` for 53 items: an empty hold list that came from a missing table, not from a
clean read (QA 2026-10-28, `merge_relabel.py:133`).

`would_execute()` now refuses to reach `eligible` when the hold source could not be read, and says why:
`queued_review:LEGAL_HOLD_UNKNOWN` + `basis: [..., staff_hold_source_absent:<table>]`. The committed variant
`sets/merges@relabel-20261028` is therefore 0 APPROVE / 159 DECLINE / 116 WAIT, and against it b1's dry run
is **219/275** (3 false approves, 3 protection violations - the same 3 items above). `verifier-eval.py
relabel-merges --assume-holds-absent-clean` writes the sensitivity variant
`sets/merges@relabel-20261028-holdsassumedclean` (53 more APPROVE, 272/275): that is the answer if the
un-deployed hold table is assumed empty, and it exists to show that the 3 disagreements do not depend on the
hold question. The shipped labels are the strict ones; nothing may reach `eligible` on a gate nothing read.

When the C1 search-visibility migration deploys, re-run `verifier-eval-merge-facts.py` (it now records
`staff_hold_table` = the source that answered, and warns on stderr when none is found) and re-label.

## Adding a verifier

Register `fn` in `scripts/verifier_eval/verifiers.py` `REGISTRY` with its set and kind, or write a shadow
log into the nightly inbox. Every PR touching a verifier prints its row from `run` in the PR body under
"Credit approval impact". Tests: `scripts/tests/test_verifier_eval.py` (also asserts reference
verifiers stay CLEAN and controls stay dirty on the committed sets).
