# Profile-link proposals (shadow)

Fable [key=profile-link-anchor] (verify-program-lead-fable-l1 and program-lead-fable-p2, 2026-10-30 07:0x-07:1xZ).
Code: `scripts/credit_verify/dspverify/link_proposal.py`. CLI: `credit-dsp-verify.py link-proposals | link-queue |
link-score`. Tests: `scripts/tests/test_link_proposal.py`.

## Why

V9 (the DSP evidence verifier, [dsp-evidence-verifier.md](dsp-evidence-verifier.md)) approves only on "credited by
id" on Spotify AND Tidal. When the PRESENTED profile carries no contributor id on a DSP, that cannot be read: the
10-30 paid queue had 0 APPROVE in 362, with 257 waiting on a link (`person_not_linked` 176, `needs_profile_link`
68, `link_mismatch` 13).

Most of `needs_profile_link` is not a linking problem. In 53 of the 55 requests whose exact name is credited
under a contributor id, that id already belongs to ANOTHER Muso profile: the claimant presents an unlinked copy of
a duplicate profile. Those are merges (C7, the merge lane: doc-verify-build-b1's `merge_candidate`,
self-merge-core-b1, profile-merge-ops-m1, executed only on the captain's L7 switch), not links. This job proposes
only the true link cases, about 4 on 10-30.

## What it reads

The V9 store `/var/lib/hydra-credit-verify/dsp-verify.sqlite`, opened read-only (`mode=ro`), under the x3 read
contract (firstmate `data/doc-verify-build-b1/x3-read-contract.md`). Per request, it takes the latest verdict of a
`verify` run whose packet names a capture that this store filed for that request (the same rule as
`Store.latest_captured_for`). Supplied-packet verdicts never count. Only WAIT verdicts are link questions. A missing
store is an error, never "no candidates".

## The rule (`link-1`)

Each claimed role x DSP reading of the presented profile P is classified. Only a `CAPTURED` reading captured after
this run's request counts. Tidal read per country: the countries that say anything must agree.

| state | meaning |
|---|---|
| LINKED | the reading credits P's linked id (and no second id under the exact name), or the catalog already holds the credited id on P |
| CANDIDATE | P is not linked on this DSP (`person_not_linked_on_<dsp>`); exactly one raw `<dsp>:` id is credited under the exact folded profile name; no catalog profile holds it |
| HELD | that id is held by another catalog profile (duplicate profile) |
| MISMATCH | P is linked on this DSP, and the exact name is credited under a different id |
| AMBIGUOUS | two or more ids carry the exact name (including the linked id plus another), two holders, or the Tidal countries disagree |
| NONE | anything else: not captured, stale, a name without an id, a different name |

For each P, the first rule that applies decides:

1. any MISMATCH: tray `link_mismatch`. Code never relinks.
2. any HELD: handoff to merge (checked first, as ruled). No row is written; the run's `counts_json.handoff_merge`
   lists the profile, its requests and the holder so it can be reconciled with b1's `merge_candidate`.
3. more than one account presents P: refused `multiple_accounts`.
4. P is not a person profile: refused `not_person`.
5. Common name: refused `common_name` when the presented name differs from the name the capture matched, the name
   is one token, or `name_collisions` is not exactly 0 (unknown counts as common).
6. Account guards: refused `guard` when the gate is not `allow`, the band is red, or any of watchlist, deny_user,
   deny_profile and idp_hold is not an explicit False.
7. Big name: refused `big_name` when any evidence track's catalog popularity is >= 60 or unknown, the linked-artist
   popularity is >= 60 or missing (also when `artists_known` says there is no linked artist), or the profile's
   credit count is >= 200 or unknown. The V9 packet has no
   popularity for the presented profile itself, so the tracks and artists it is credited on stand in for it.
8. AMBIGUOUS anywhere, two different candidate ids for one DSP across P's readings, or one DSP read LINKED in one
   reading (any role, any verdict) and CANDIDATE in another: tray `id_conflict`.
9. Evidence. An agreeing track is one where BOTH Spotify and Tidal credit the claimant in ONE verdict's same-run
   capture, each LINKED or CANDIDATE, with at least one CANDIDATE. Readings from two verdicts (two requests or two
   runs on one track) are never combined into agreement. Tracks are independent when they have different track ids,
   non-empty disjoint ISRC sets and different base titles ("Song (Remix)" is the same song).
   - 2 or more independent agreeing tracks: proposal, basis `two_tracks`, confidence 0.9 (0.95 with 3 or more).
   - 1 agreeing track plus a processed claim of P by the same account (Trino, `claiming.status = 'processed'`;
     unknown counts as no claim): proposal, basis `track_plus_claim`, confidence 0.85.
   - otherwise refused: `single_dsp` (never on both DSPs on one track) or `one_track`.

The output is one proposal row per DSP that has a CANDIDATE. Spotify and Tidal ids are different namespaces; each
row records the other DSP's id proposed in the same run (`partner_contributor_id`). A name alone is never enough:
every proposal is a raw contributor id that the DSP itself credits, in this job's capture, on a track the claimant
claimed.

## Where it writes

The writes go to tables `link_proposals` and `link_runs` in the decider ledger
`/var/lib/hydra/credit-review/ledger.sqlite3` (`$CREDIT_REVIEW_LEDGER`).

- `kind` is `link_proposal` or `link_tray`. `mode` is always `shadow`: a trigger refuses any other value.
  Each row also carries `rule_version`, `dsp_version`, `decided_at`, `confidence`, `request_ids`, `verdict_ids`
  (the V9 rows the evidence came from), `evidence_json` (per track: ids, title, ISRCs, roles, per-DSP credit,
  `captured_at` and capture ids) and `evidence_sha256`.
- The table is append-only (triggers). A unique key `(kind, rule_version, profile_id, dsp, contributor_id,
  reason)` means hourly re-runs record each proposal once.
- It is deliberately NOT the decider's `decisions` table. `decide.recently_decided`, the latest-decision-per-request
  readers (`decide.py`, `score_approve.py`, `proof/stage2.py`) and `verify_notify` read every `decisions` row as a
  credit decision. A link proposal there would make the decider skip the request or misread its standing decision.

The cron `credit-profile-link-proposals` runs hourly at :45 with kill switches `/etc/hydra/credit-dsp-verify.disabled`
and `/etc/hydra/credit-verify.disabled`. `--dry-run` prints what it would record and writes nothing.

## The bar before any link write

```
credit-dsp-verify.py link-queue  > queue.jsonl        # blind: no basis, no confidence
credit-dsp-verify.py link-score --labels labels.json   # {proposal_id: correct|wrong|unsure}; exit 1 = not met
```

The bar is met only when all of these hold:
- at least 24 h of shadow since the first proposal;
- every proposal is labelled when there are fewer than 100, otherwise at least 100 are labelled;
- verifier-eval-v1 labels 0 `wrong` and 0 `unsure`.

Then comes the core profile-link route: core-backend, a registered automation, server-side contributor-id
validation against the IDP capture, an audit row before the write, and a reversible unlink. `approved_by` is the
captain (captain-1028-213x). It lands on develop, then the master twin in the 02-13Z window. Any prod DDL needs the
captain's "DDL go". After a link lands, V9 re-reads the request ("credited by id") and the anchored approve path
(credit-refresh-t01b) takes it.

Nothing here writes core, links a profile, approves, declines or messages anyone.
