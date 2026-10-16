# credit-retro r1: role-scoped take-back + prepared verify-with-documents waves

Ops script: `scripts/credit-retro.py` (package `scripts/credit_retro/`). Tests:
`python3 scripts/tests/test_credit_retro.py` (run in PR Validation).

## Why

From 05-18 to 10-11 the hydra credit-verification batch approved validator-declined
requests on an inverted signal (see `AGENTS.md` "Credit approvals" and
`docs/credit-verification/ai-credit-reviewer.md`). The f1 retro review re-tiered the
09-01 -> 10-11 approvals (firstmate data `credit-retro-hold-docfraud-f1`, `part-c.md`;
Part A covers the older loose paths in `report.md`). Captain, 2026-10-15:
- ~22:00Z: "i want you to focus on fixing the ones that Nick automated and let through a
  lot of credits - i think quite a few should not have been allowed in";
- ~20:00Z: "Deletes must confirm the credit was removed from spotify or tidal first or prove
  that it is a different profile in our system that the credit belongs to";
- ~22:02Z: "i still think AI can make the decisinos with proper documentation (without fraud)
  and with proper support from internet and trust of the profiles";
- ~21:50Z: Jay Baumgardner's (user 15) existing profile is left alone.

## What it does (firstmate decision 001, 2026-10-15T23:09Z, "A + X")

**A. The take-back is role-scoped.** It removes ONLY the proven one-person roles, through
`DELETE /admin/track/:trackId/profile/:profileId/credits {credits:[role]}`. It never moves a
credit request to another status and never sends the generic notice.
- Why not the whole request: the server forbids `approved -> user_verification_needed`. The
  only legal exit is `approved -> unverified`, and that publishes a catalog delete of every
  role on the request (`statusTransitions.js`, `updateStatus.js` in core-backend). 36 of the
  40 take-back requests carry unproven roles (138 of their 178 credits), and the captain's
  delete rule forbids deleting those.
- The route writes a `credit_removal_events` row. `reconcileOrphanApprovedCredits` honours
  it, so the role is not re-added while the request stays `approved`.
- Every unproven role stays live and goes to the verify waves.

**X. Only a named human runs it.** core-backend #10310 refuses every agent or API token on
this route (403 `credit_removal_agent_refused`). The removal-approval path
(core-backend #10578) is not wired yet. So `apply` and `revert` run from nick@'s or jan@'s
own login: `--login` prompts for the email and password and stores neither.
`--session-file` takes a 0600 file holding their own session token. Reads (`plan`,
`readback`, `prepare-waves`) can use hydra's GET-only wrapper.

## The live gate (re-run per row immediately before each write)

Each row is one (request, role) from `scripts/credit_retro/manifests/takeback-r1.jsonl`:
40 roles, 40 requests, 21 users. A role is in the take-back only when the web check read
THAT role's credit. 8 Mixing/Mastering roles whose only web check was about a different
role on the same track (users 161128 x5, 1404192, 182594, 221452) were moved out: they are
documentation-ask rows (tier HOLD in the population, asked in the verify waves), never
removed on borrowed evidence.

The manifest records the review-time evidence: the trusted holders and a cited
public-credit URL. The ledger's `approval_ref` holds the full decision reference, the
approval id and the URL. The logged `X-Removal-Approval-Ref` header (the server caps it at
255 chars) is `approval <id> | <URL> | credit-retro-r1 fm001`: the approval id and the URL
come first, so the cap can only ever cut the short decision tag.

| Gate | Skip reason |
|---|---|
| user 15 is excluded | `excluded_user` |
| The request still exists, is `approved`, has the same user/profile/track, and still lists the role | `request_not_found`, `request_not_approved:*`, `user_mismatch`, `role_not_on_request` |
| The claimant is not one of the track's own artists (by profile id or by name) | `claimant_is_track_artist` |
| The claimant still holds the role (a live muso credit) | `claimant_credit_already_gone` |
| Spotify/Tidal/MLC/Jaxsta credit the role to someone else and NOT to the claimant. The claimant is matched by raw-profile link, name, known-as names or legal name (`credit_review.evidence.classify_roles`) | `not_contradicted_live:CONFIRMED` / `:UNVERIFIABLE` |
| A person named in the cited evidence is still among those trusted holders | `evidence_holder_changed` |

Any skip is recorded with its reason and is never retried around. Those roles join the
verify waves.

The gate also records, without skipping, whether the role is the claimant's last live
credit on the track (`last_credit_on_track` in the row's before state). `plan` counts those
as `would_remove_last_credit_on_track` and marks the row "(last credit on track)";
`report` lists the removed ones under `last_credit_on_track`.

**Dry-run 2026-10-15 23:27Z (agent read-only, `plan-20261015T232735Z-c029a4`),** over the
earlier 48-row manifest that still held the 8 borrowed-evidence rows (run `plan` again for
current counts): 30 roles would be removed, on 24 requests from 13 users. 18 roles were skipped:
- 11 `UNVERIFIABLE`: no trusted source holds the role at all.
  - The 7 Chris Doss rows (user 263354): the "other holder" is user 15's own Muso claim.
    That is not a trusted source, and user 15 is left alone.
  - The 3 rows for user 99591: their claimed holder comes from Bandcamp, not from a
    trusted source in our catalog.
  - User 1387937: 1 row.
- 3 `CONFIRMED`: Spotify AND Tidal credit the claimant. These are users 221452 (2 rows)
  and 183362, and the f1 review was wrong about them.
- 2 `claimant_is_track_artist` (user 1404192, a self-release, so an alias risk).
- 1 `evidence_holder_changed` (user 266548: "Charles Fischer" in the evidence vs "Charles
  Fisher" at the source).
- 1 `claimant_credit_already_gone` (user 20313).

## Runbook (nick@ or jan@)

```bash
S=/opt/hydra/scripts/credit-retro.py     # on node-8 (or a checkout of main)
python3 $S plan                           # dry-run; prints the plan run id
python3 $S stage --plan <plan_run>        # approval set(s); Nick or Jan approves each (see Approval path)
python3 $S apply --plan <plan_run> --approval <id> --login --yes-remove --only '<one row_id>'   # canary
python3 $S readback --run <apply_run>     # canary removed, trusted holders intact
python3 $S apply --plan <plan_run> --approval <id> [--approval <id2>] --login --yes-remove
python3 $S readback --run <apply_run>     # re-run until no row is `pending` (ingestion is async)
python3 $S report --run <apply_run>       # counts, refused/errored rows, the revert command
```

**One-command revert:** `python3 $S revert --run <apply_run> --login`. It re-adds exactly
the roles that run removed (a POST to the same path) and never re-adds a role twice. Verify
with `readback --run <revert_run>`. A removal that dropped the last credit on a track also
suppresses the feed activity (`deleteTrackProfileCredits` -> `dropTrackActivities`), and a
revert does not bring that activity back. This can happen in r1: 4 take-back requests carry
only their proven role, so unless the claimant holds another credit on that track, the
removal is their last one there. The gate records it per row (`last_credit_on_track`), and
`plan` and `report` list those rows; read them before `apply`.

`apply` refuses to run without a finished `plan` of the same manifest bytes from the last
24 h, and it only ever considers the rows that plan showed as `would_remove`. A row the plan
skipped is never removed by that apply, even if the live data changed since; run `plan`
again to pick it up. A server 403 stops the run, because every #10310 refusal is about the session, not
the row. `--approval` is required: there is no unapproved apply.

Each DELETE is recorded as `sent` in the ledger before it goes out. When its response is
lost (transport error, timeout), apply reads the claimant's live credits and records
`removed` or `not_removed`, then stops the run; if that read fails too the row is
`indeterminate`. A row left `sent` (a crash) or `indeterminate` is listed under
`unresolved` by `report`. The next `apply` on the manifest, `readback` and `revert`
reconcile those rows against live credits first, recording the result in the original run,
and refuse while the result is still unknown. `prepare-waves` refuses until they are
resolved.

`revert` and `restore` work the same way for the re-add: each POST is recorded as `sent`
first; a lost response is resolved by a live read (`re_added`, `not_re_added` or
`indeterminate`) and stops the run. An unknown re-add blocks the next `revert`/`restore`,
`readback` of that revert and `prepare-waves` until a live read resolves it, so a re-added
credit is never POSTed twice and never announced as removed.

### Approval path (core-backend #10597, merged to develop 2026-10-16 03:03Z)

Firstmate 007: once core-backend #10597 lands, route the take-back through its removal
approvals instead of a hand-run session alone. It adds `POST /admin/credit-removals` (stage),
`POST /:id/approve` and `/:id/reject` (a named human), and `GET /:id`.

```bash
python3 $S plan
python3 $S stage --plan <plan_run>          # agent token is fine: staging grants nothing
#   -> Nick or Jan approves each set once, from their own session: POST /admin/credit-removals/<id>/approve
python3 $S approval-status --id <id>         # status, pairs, consumed
python3 $S apply --plan <plan_run> --approval <id1> [--approval <id2>] --login --yes-remove
```

- `stage` posts the plan's would-remove rows: one pair per profile+track with its roles.
  - `sourceRef` names the plan run, the manifest sha256 and the set number.
  - Fable: an approval alone is never enough; the evidence must be attached. #10597's
    stage body has no per-pair evidence field (the `payload` column is not exposed), so
    every pair's public-credit URL goes, untruncated and keyed `[profile/track/role]`,
    into its set's `reason` (2,000 chars). When they do not fit one set, the rows are
    split over as few sets as needed (the 2026-10-15 dry-run's 30 rows needed 2 sets); a
    profile+track never spans two sets.
- `apply --approval <id>` (required, repeatable) refuses unless every named set is `approved` and unexpired. It then
  removes only the rows whose (profile, track, role) the set approved and has not consumed
  (`not_in_approval` otherwise). It records the approval id in the ledger and in the
  logged reference header.
- Still a gap: #10597 leaves the removal routes untouched (delegation flag off). The DELETE
  therefore still needs a named human's session, and the server does not consume the pairs
  yet. Once the consume wiring lands (core-backend #10578's coverage on the removal route),
  `apply --approval` is where the agent token plus the approval id replaces the session.
  That change is one transport branch.

## Ledger

`--state-dir` defaults to `/var/lib/hydra/credit-retro` (`CREDIT_RETRO_DIR`).
- `ledger.sqlite3` holds `runs`, `run_ends` and `events`. Triggers abort any UPDATE or
  DELETE.
- `runs/<run_id>.jsonl` is an fsynced per-run mirror.

Each event has: row id, request/user/profile/track, role, action
(`gate|stage|remove|readback|revert|prepare`), outcome, HTTP status, before state (the live
request, the claimant's live credit, the trusted holders, whether it is the claimant's
last credit on the track), after state, evidence URL,
approval ref, reason, actor (the session's email) and run id.

## The removal policy (captain, 2026-10-16 ~00:35Z, via firstmate 005)

> "how many credits were approved without documentstion i dont want to lose users unless its
> obvious fraud feom tbe past"

This narrows the 23:40Z ruling ("if no valid verification comes it should be removed") for
PAST credits.

| Credits | Removed when | Silence means | Tool |
|---|---|---|---|
| **Past, obvious evidence-backed fraud**: a trusted public credit names someone else for a one-person role (the proven take-back rows). Fraud-pattern accounts with contradictions or forged documents, and burst accounts only after a whole-profile review shows fraud, are removed by a reviewed decision. | now, after the live gate | n/a | `plan` / `apply` (manifest-driven; a reviewed fraud decision gets its own manifest) |
| **Past, everything else**: Nick's batch, the loose paths, the editing claims (all approved before 2026-10-16) | **never for silence** | the credit stays, flagged unverified internally (board / valuation basis) | `prepare-waves` (friendly ask) |

A valid document always raises trust. A past credit with proof counts as verified.

## Documentation-request waves for past credits (prepared, never sent)

Three rulings shape these waves:
- Captain, ~23:35Z (via firstmate 002): "im referring to before when nick made changes and
  did a trust verify flow and now we have a lotnof credits to verify with documents and give
  people 30 days to send something in for the ones missing documents".
- Narrowed at 00:35Z (above): the ask is friendly, with no removal threat and no deadline
  language.
- Narrowed again at ~02:00Z (firstmate 006): "are you annoying people fornbackup that we
  shpuldnt be?". Ask only GENUINE risk.

**The past population** (`manifests/population-r1.jsonl.gz`, 27,811 requests / 2,305
users) is the base.

| Tier | Requests |
|---|---|
| Part C HOLD | 1,281 |
| The 36 take-back requests' unproven roles | 36 |
| WATCH velocity | 1,283 |
| WATCH big-unverifiable | 63 |
| KEEP small-unverifiable | 13,242 |
| Part A HOLD | 45 |
| `EDITING_LOOSE` | 11,861 |

KEEP_established, KEEP_web_credible (aliases), KEEP_confirmed and user 15 were never in it.

**Who is ASKED** (`waves.select`):

| Ask | Unit | Count (default `--editing-min-pop 30`) |
|---|---|---|
| Part A HOLD | rows | 45 requests / 19 users |
| Part C HOLD, incl. the unproven roles of take-back requests | rows, big tracks first | 1,317 requests / 272 users |
| Take-back roles not removed (gate skip, refusal, revert) | rows | 4 requests before any apply |
| WATCH velocity accounts | ONE ask per account (three tracks of their choice) | 9 accounts |
| Editing burst accounts: at least 40 loose editing claims and a peak of 40/day, kept only if the whole-profile review of their 8 biggest tracks did not find trusted sources naming them as editor on at least half | ONE ask per account | 27 of 29 (Benedikt Schröder and René Möller cleared) |
| Editing rows of everyone else: a trusted source names a different editor (any track), or unverifiable on a track with popularity >= 30 (the editing role only) | rows | 702 requests / 94 users |

**Total: 417 users (141 paying), 2,069 requests / 5,124 role credits listed, plus 36
account asks.** Waves: W-01 and W-02 (200 a day, paid first, then big tracks), W-03 17 users.
With `--editing-min-pop 60` (big tracks only) the total is 361 users (123 paying). Firstmate's
target was ~300-350; the choice of mid (30) vs big (60) is the lever.

**Who is NOT asked:** 25,746 requests from 1,888 users. These are the small unverifiable
claims, the big-unverifiable WATCH rows, small unverifiable editing claims, and ordinary
small accounts. They are left alone and written to `<run>/unverified-internal.jsonl`
(request ids only), the basis for the internal unverified flag on the board / valuation.

**Rules:**
- **At most one message per user.** Rows and account asks are merged into one payload
  (`account_asks[]` is a section).
- **Never re-ask someone who sent proof.** `prepare-waves --verify-ledger` drops every
  request already covered by a proof-tagged note. With live reads it also skips accounts
  that ever sent proof (`skip_already_sent_proof`) or already got a past-credit ask
  (`skip_already_asked`). If the send ledger is absent or not mounted, nothing is proven
  safe: every payload is marked `send_ledger_unavailable` (not sendable) and the index says
  `send_ledger: UNAVAILABLE`.
- **Nothing is sent** before Fable's copy GO and the merged send tool.

The editing selection comes from `manifests/editing-ask-r1.json`. It was built from the
live trusted-credit check on 2026-10-16: 3,837 rows. The burst accounts' whole-profile
sample is 8 tracks each, and every non-burst editing row was checked.

`python3 $S prepare-waves [--apply-run <apply_run>] [--per-day 200]` writes one payload per
user to `<state-dir>/waves/<run_id>/<wave>/user-<id>.json` (mode 0600) and an `index.json`.
`--apply-run` only selects the take-back manifest that run used (and refuses if it changed
since); without it, `--takeback` names the manifest.
- **T-01** (10-16): the take-back users. The note about their removed (proven) roles and the
  friendly ask for their other credits go in one message. "Removed" means removed by ANY apply
  run on the take-back manifest (the canary, the full run, re-runs after a stop) and not
  re-added by a revert/restore, so a removed role is never asked about again. `index.json`
  lists those runs under `apply_runs`.
- **W-01..W-nn**: every other ASKED user, `--per-day` users a day from 10-16. Paid users
  come first, then by the user's biggest current track, then by credit count.

Payload contents:
- the `--credits-file` shape of `scripts/intercom-verify-request.sh` (`user` + `credits[]`,
  capped at that tool's 200 per message, biggest tracks first);
- `groups[]` by role (mixing-mastering / producer / writer-composer / engineer-assistant /
  musician);
- `request_ids_all`;
- `send_campaign: retro-past`, the send tool's past-credit campaign
  (`credit_review/verify_ledger.py` `CAMPAIGNS`). This is a no-removal campaign; the send
  tool must never use its removal-promising `verify-live` campaign for these. The same name
  is what `--verify-ledger` reads back to skip users already asked;
- `removal_threat: false` and `deadline_language: false`;
- `follow_up_on`: one optional friendly nudge at day 14 (`retro-follow-up`), no deadline;
- `flag_unverified_after` (day 30, internal flag only);
- `on_silence`: the credit stays, flagged unverified internally, never removed;
- `proof_channel` (Intercom now, email when E-IN lands);
- `credits_stay_visible: true`.

Online reads (the default) fill in the account email from the credit requests themselves,
refresh titles, and drop credits that are no longer approved. A user whose live read fails
is written with status `live_read_error` and is not sendable (counted under
`not_sendable`); prepare again when the API answers. `--offline` skips Muso entirely.

Templates are in `retro-drafts/`. The past-credit grouped ask, the account ask, the
follow-up and the take-back note are new drafts that still need Fable's review. None of them
carries a removal date.

Velocity and editing-burst accounts get ONE ask each (`account-three-tracks`): three tracks
of their choice from the burst. A user who also has HOLD rows gets that as a section of the
same grouped message.

## Restore

When valid proof arrives after a take-back removed a role, `restore` re-adds exactly that
request's removed roles from one apply run and records the proof reference:

```bash
python3 $S restore --run <apply_run> --request <id> --proof-ref "<conversation / review id>" --login
```

It runs only from nick@'s or jan@'s own session (core-backend #10310), like the take-back.

## Rebuilding the manifests

`scripts/credit_retro/build_manifests.py --tiers-a ... --tiers-c ... --rows-a ... --rows-c ... --webchecks ...`
reads the f1 outputs (plus `--editing`, the replica editing-claim extract kept in firstmate
data `credit-retro-exec-r1/editing-loose-rows.json.gz`). The committed manifests contain only ids, public track and artist
names, public-credit URLs and a paying boolean. The population file is gzip with mtime 0,
so a rebuild is byte-identical. A contradicted role whose web check read only a sibling role
on the same track is never a take-back row; it goes to the population as a HOLD role. The
tests pin the take-back set at 40 roles, 40 requests and 21 users, every one with an
own-role web check; the population tier counts; the 138 residual roles; the 9 velocity accounts;
and the absence of user 15.
