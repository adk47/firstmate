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

**A. The take-back is role-scoped.** It removes ONLY the proven one-person roles (one profile
also has a published-roster exception: see "Published-roster take-back: Big Boy only"): each is one
(profile, track, role) pair of an approval set, spent by core-backend #10638
`POST /admin/credit-removals/:id/execute` through `removeTrackProfileCredits` (the same removal
as `DELETE /admin/track/:trackId/profile/:profileId/credits {credits:[role]}`). It never moves
a credit request to another status and never sends the generic notice.
- Why not the whole request: the server forbids `approved -> user_verification_needed`. The
  only legal exit is `approved -> unverified`, and that publishes a catalog delete of every
  role on the request (`statusTransitions.js`, `updateStatus.js` in core-backend). 36 of the
  40 take-back requests carry unproven roles (138 of their 178 credits), and the captain's
  delete rule forbids deleting those.
- The route writes a `credit_removal_events` row. `reconcileOrphanApprovedCredits` honours
  it, so the role is not re-added while the request stays `approved`.
- Every unproven role stays live and goes to the verify waves.

**X. Only a named human executes it, and only through the tool (firstmate 025/026).** The agent
stages (#10597); Nick or Jan decides each pair; execute (#10638) refuses every agent or API token
(`requireHumanApprover`), as #10310 does on the removal routes. So `apply` (which calls execute)
and `revert` run from nick@'s or jan@'s own login, and `apply` sends each user's notice in the
same step: sets staged by credit-retro are never executed from the board, or the notice would
not go out with the removal. `--login` prompts for the email and password and stores neither.
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
public-credit URL. The ledger's `approval_ref` holds the approval id, the full decision
reference and the URL; the set's `reason` on the server carries every pair's URL.

| Gate | Skip reason |
|---|---|
| user 15 is excluded | `excluded_user` |
| The row is not marked `excluded` in the manifest (14 rows: 5 for alias risk, live-edition mismatch or press that may name the claimant; 9 because their users (119347, 178113, 178851, 260893, 1392361, 1403656) sent documents in Intercom, and a human must check none covers the credit before any removal, captain 013) | `excluded_row` |
| **Live exclusion sources, read fresh by every `plan` and `apply` (firstmate 020).** Proof on file in credit-trust `proof-on-file.json` (an entry with a `request_id` matches that request, one without matches every row of the user). Only a Big Boy row can be cleared, by a named human's board answer (see "Published-roster take-back") | `proof_on_file:<kind>` |
| No proof-tagged note in Caroline's send ledger covers the request or the request's account | `proof_tagged` |
| The user is not in `manifests/doc-submitted-r1.json` and the request is not one a human approved there | `doc_submitted`, `human_approved_after_doc` |
| The row carries checked evidence for ITS OWN role (`evidence.verified` = `public_page`: a page of this track/release naming the other person in this role, `published_roster` (Big Boy only, see below), or `trusted_dsp_only`: a CURRENT Spotify or Tidal credit on this recording naming them, with `evidence.sources` only `spotify`/`tidal` and the URL on `open.spotify.com` or `listen.tidal.com`, the URL's own source among `evidence.sources`; never Jaxsta or MLC alone). `evidence.url` is the cited `evidence_url`, and every name in `evidence.names` is quoted in the recorded `evidence.note` (only those names are cited to the user). An optional `evidence.corroboration` (e.g. a press article) must be a link Caroline's gate accepts (public https, at most 300 characters, never a Muso or internal surface: `verify-request-notes.md` → Take-back notices) other than `evidence.url`, checked here at plan time so a bad link shows up as `evidence_unverified` before approval instead of getting that user's set withheld as `notice_refused` at apply (firstmate 041); it is cited next to the evidence, never instead of it (`takeback-notice.md`). 10 rows pass this and are not excluded (users 197122, 161128, 182594, 150514; checked 2026-10-16, row 8999a707 re-checked 2026-10-18) | `evidence_unverified` |
| The request still exists, is `approved`, has the same user/profile/track, and still lists the role | `request_not_found`, `request_not_approved:*`, `user_mismatch`, `role_not_on_request` |
| The claimant is not one of the track's own artists (by profile id or by name) | `claimant_is_track_artist` |
| The claimant still holds the role (a live muso credit) | `claimant_credit_already_gone` |
| Spotify/Tidal/MLC/Jaxsta credit the role to someone else and NOT to the claimant. The claimant is matched by raw-profile link, name, known-as names or legal name (`credit_review.evidence.classify_roles`). Big Boy's rows also pass on `OTHERS_ONLY` for a `published_roster` row, and are refused while a trusted source credits him on the track's engineering team (see "Published-roster take-back") | `not_contradicted_live:CONFIRMED` / `:UNVERIFIABLE`, `claimant_on_engineering_team` |
| A person named in the checked evidence (`evidence.names`) is still among those trusted holders | `evidence_holder_changed` |
| `trusted_dsp_only` and `published_roster` only: a named person is still a live holder in EVERY cited source (Spotify/Tidal; the notice names each one and links the URL's), not only in Jaxsta/MLC or in just one of them | `dsp_holder_vanished` |
| **Last, only for a row that passed every gate above and would be removed (firstmate 021).** Org affiliation (credit-trust `org-affiliation.json`, captain 2026-10-16 ~18:36Z: "make sure these guys you remove credits or ban are not part of any major label or publisher too"): `contributor`, `verified_org` or `authenticated_domain` is human review + a polite contact, never automatic; `claimed_unverified` and `none` are allowed only with `coverage: full` and shown in the plan's `affiliation=` column; a user with no verdict is skipped, and so is one whose coverage is not `full`. A row that failed an earlier gate keeps that reason and is never in `needs_human_review` | `org_affiliated` (listed under `needs_human_review` by `plan` and `report`), `affiliation_unknown`, `affiliation_partial` |
| The user's take-back notice would go out today and Caroline's gate accepts it (see the notice section) | `notice_would_defer`, `notice_refused` |

Any skip is recorded with its reason and is never retried around. Those roles join the
verify waves.

The gate also records, without skipping, whether the role is the claimant's last live
credit on the track (`last_credit_on_track` in the row's before state). The other roles the
same run removes from that profile and track count as gone (Main Attraction and Believer each
lose Mixing and Engineer together). `plan` counts those
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
python3 $S stage --plan <plan_run>        # one approval set per user; Nick or Jan decides each pair (see Approval path)
python3 $S apply --plan <plan_run> --approval <one user's set> --notice-approved-by <SlackUID> --login --yes-remove   # canary
python3 $S readback --run <apply_run>     # canary removed, trusted holders intact
python3 $S apply --plan <plan_run> --approval <id> [--approval <id2> ...] --notice-approved-by <SlackUID> --login --yes-remove
python3 $S readback --run <apply_run>     # re-run until no row is `pending` (ingestion is async)
python3 $S report --run <apply_run>       # counts, refused/errored rows, the revert command
```

**Canary first, alone (Fable v3, firstmate 035): 182594's set (one role, Tidal-only).** A set
is one user, so the canary never touches anyone else. It runs first and ALONE; every other set
the live plan stages runs only after these canary checks pass:
1. the notice was delivered (the Intercom conversation event, not only the gate's exit 0);
2. the removal is tombstoned: `readback` shows the role gone with the trusted holder intact,
   the pair is consumed with a `credit_removal_events` id (`approval-status --id <set>`), and
   24 h later the role has not come back (the orphan reconciler honours the event);
3. the restore path is ready for that row: `report` prints the revert command, and
   `restore --run <apply_run> --request <id> --proof-ref <ref>` is the one used if the user
   replies with a document that checks out.

Then every other staged set. As of the 2026-10-18 plans that is only 161128's set: 197122 and
150514 are held by proof on file (documents they sent after the 10-16 snapshot,
`proof_on_file:human_approved_after_doc`), and any user the live gate releases later also waits
for the canary. A user who already got a message that UTC day has their whole set withheld
as `notice_would_defer` and executed on a later day (the set stays approved for 7 days).

**Before the first real `stage` (Fable v3 §4):** Caroline's send ledger has its
`verify_messages` table (every deploy creates it, schema: `verify-request-notes.md` → Operate;
without it every run is `proof_source_unavailable`, by design); prod answers
`GET /admin/credit-removals` (core #10614 re-twin deployed); the `takeback-notice` campaign is
in Caroline's gate with the wording rules below enforced by its renderer.

**One-command revert:** `python3 $S revert --run <apply_run> --login`. It re-adds exactly
the roles that run removed (a POST to the same path) and never re-adds a role twice. Verify
with `readback --run <revert_run>`. A removal that dropped the last credit on a track also
suppresses the feed activity (`deleteTrackProfileCredits` -> `dropTrackActivities`), and a
revert does not bring that activity back. This can happen in r1: 4 take-back requests carry
only their proven role, so unless the claimant holds another credit on that track, the
removal is their last one there. The gate records it per row (`last_credit_on_track`), and
`plan` and `report` list those rows; read them before `apply`.

`apply` refuses to run without a finished `plan` of the same manifest bytes from the last
24 h. A set holding a pair that plan did not show as `would_remove` is withheld whole
(`pair_not_in_plan`), even if the live data changed since; each such pair is recorded
`withheld` as `pair:<profile>/<track>/<role>`, so the CLI exits 3; run `plan` and `stage`
again. A server 403 stops the run, because every refusal is about the session, not the pair.
`--approval` is required: there is no unapproved apply.

**Whole sets, never part of one (firstmate 026).** Immediately before each execute, `apply`
re-runs every gate on every pair the set would spend and pre-flights the user's notice. ANY
failure withholds the WHOLE set: nothing of that user's is removed, every row is recorded
`withheld` with its reason, `report` lists them under `withheld`, and the CLI exits 3 so
Nick or Jan decides with the reason. Core cannot un-approve a decided pair (`/decide` 409s,
`/reject` is staged-only), so a withheld set stays approved and unspent until it expires
(7 days): a passing re-run on a later day executes it; a lasting reason lets it expire.
A set executes only once EVERY pair is decided: one undecided pair withholds the whole set
(`pair_undecided`). Core decisions are write-once (every decide path is guarded by
`decision IS NULL`), and #10638 execute takes no expected-pairs condition, so an undecided
pair is the only way what an execute spends could grow after the live gate: a pair approved
between the gate and the POST would be removed without being re-proved or announced. With
every pair decided, the execute spends exactly the pairs that were gated.

A pair already consumed with no removal recorded by this manifest's apply runs was executed
outside the tool (the board). `apply` reads the live credit: gone is recorded `removed`
(`executed_outside_tool`) and announced in that run; still credited is recorded `withheld`
(`consumed_still_credited`, exit 3); an unreadable credit is `indeterminate` (unresolved).

Each pair is recorded as `sent` in the ledger before the execute goes out. The server's
per-pair result decides: `removed` (or `already_executed`) is a removal; any other result
(`error`, `refused`, `not_executable`, `consumed_unconfirmed`, missing) is resolved by a live
read of the claimant's credits, never assumed. When the response is lost (transport error,
timeout, or any non-2xx other than 403, such as a 502 from the ingress), apply reads the live credits and records `removed` or `not_removed`, then stops
the run; if that read fails too the row is `indeterminate`. A row left `sent` (a crash) or `indeterminate` is listed under
`unresolved` by `report`. The next `apply` on the manifest, `readback` and `revert`
reconcile those rows against live credits first, recording the result in the original run,
and refuse while the result is still unknown. `prepare-waves` refuses until they are
resolved.

`revert` and `restore` work the same way for the re-add: each POST is recorded as `sent`
first; a lost response is resolved by a live read (`re_added`, `not_re_added` or
`indeterminate`) and stops the run. An unknown re-add blocks the next `revert`/`restore`,
`readback` of that revert and `prepare-waves` until a live read resolves it, so a re-added
credit is never POSTed twice and never announced as removed.

### Approval path (core-backend #10597 stage, #10631/#10633 decide, #10638 execute)

Firstmate 025/026: the agent stages, a HUMAN decides and executes, and the tool sends the
notice in the same step.

```bash
python3 $S plan
python3 $S stage --plan <plan_run>          # agent token is fine: staging grants nothing; one set per user
#   -> Nick or Jan decides each pair from their own session (board, or POST /admin/credit-removals/<id>/decide
#      | /approve, which stamps every pair approved)
python3 $S approval-status --id <id>         # status, pairs (decision, consumedAt)
python3 $S apply --plan <plan_run> --approval <id1> [--approval <id2>] --notice-approved-by <SlackUID> --login --yes-remove
```

- `stage` posts ONE SET PER USER: one pair per profile+track with its roles.
  - #10638 execute spends every approved pair of a set at once and cannot pick a subset,
    while the notice, the daily cap and every exclusion are per user. One user per set means
    one user's problem never blocks or forces another's removal.
  - `sourceRef` names the plan run, the manifest file and its sha256, and the user.
  - A row resting on the Spotify/Tidal credit alone carries `evidence_class=dsp_track_level`
    in its evidence line, so the board can tell it apart from a public credits page.
  - Fable: an approval alone is never enough; the evidence must be attached. The stage body
    has no per-pair evidence field, so every pair's public-credit URL goes, untruncated and
    keyed `[profile/track/role]`, into its set's `reason` (2,000 chars). A user whose
    evidence does not fit one set is not staged (`user_evidence_exceeds_one_set`) and goes
    to a human.
- `apply --approval <id>` (required, repeatable, one user's set each) refuses unless every
  named set is `approved` and unexpired. A set is approved once ANY pair is (Fable 024), so
  `apply` only ever spends, and announces, pairs whose OWN `decision` is `approved` and that
  are not consumed; the server enforces the same (`consumeCoverage` carries
  `decision = 'approved'`). A rejected or undecided pair is never removed and never in a
  notice. The approval id is in the ledger's `approval_ref`.
- Never execute a credit-retro set from the board: the notice is sent by `apply` in the same
  step as the execute.
- Needs on prod: the master twin of #10597/#10631/#10633/#10638 (core-backend #10614,
  re-twinned at one frozen develop sha for the next core window).

### The take-back notice (captain requirement, firstmate 012)

Every take-back tells its user, when the removal executes and never before. The copy is in
`retro-drafts/takeback-notice.md`. It is one short, polite message per user, and it says:
- which credit and role was removed;
- why: who the public credits name, with the evidence link;
- how to dispute it: reply with one document.

Removal and notice are ONE step (firstmate 014): a role is never removed without its
message going out.

- **Approval of the copy:** `apply` and `notify` require `--notice-approved-by <SlackUID>`,
  the human who approved THIS copy and run. There is no default and the captain is never
  assumed; the id is passed to the gate as `--approved-by` and recorded with every
  `notify` event in the ledger.
- **Before the execute:** `apply` resolves each affected user's account from a
  credit request that still belongs to that user (request `userId` and account id). A user
  with no such request has their whole set withheld (`user_mismatch` or `request_not_found`):
  nothing of theirs is removed and nobody is messaged. The notice is addressed like every
  other gate campaign, by the account's `users.neptuneProfessionalId` (and Auth0 subject),
  read from the replica (`verify-request-notes.md` → The gate): a user without one has
  their set withheld (`no_professional_id`), and an unreadable replica refuses the whole run.
  It then validates that user's notice through Caroline's gate
  (`intercom-verify-request.sh send --campaign takeback-notice --validate`).
  - If the gate would defer it today (exit 3: one message per user per UTC day), that
    user's set is withheld this run (`notice_would_defer`). It stays approved and goes on a
    later day's run, with its message.
  - If the gate refuses that user's notice (exit 1, e.g. its leak check on a track title,
    name or link containing an issue number or a word Caroline's sanitizer redacts), ONLY that
    user's whole set is withheld (`notice_refused`, with the gate's reason in `report`'s
    `withheld`; `apply` exits 3 for Nick or Jan). Every other user's set goes ahead with its
    notice (firstmate 041).
  - If the gate cannot run at all (script missing, usage/environment error, hung), or an
    account has no email, the whole run is refused: nothing is removed for anyone.
- **After the execute:** one notice per user lists the roles the server reported removed in
  THIS run (never a pair it did not report removed). Every
  outcome (`sent`, `deferred`, `failed`) is recorded in the apply run as action `notify`,
  without the email. If the run stopped early, the roles it did remove are still announced.
  A send-gate call that hangs or cannot run is recorded as `failed`, and the run is always
  finished in the ledger.
- **Removals confirmed later:** an execute whose result was unknown (`sent` after a crash,
  `indeterminate` after a lost response) and that a later live reconcile records as
  `removed` is announced by the next `apply` before anything new is removed (counts
  `earlier_notice_*`). `report` lists every removed role still owed a notice under
  `unnotified`; a role re-added by `revert`/`restore` is never announced.
- **Never reported complete while a notice is owed:** if any role the run removed has no
  `sent` notice (the send deferred or failed after the execute), `apply` exits non-zero naming
  the run and its unnotified rows. Every later `apply` first retries the notices earlier runs
  owe and removes nothing new until they are all sent.
- **Retry:** `python3 $S notify --run <apply_run> --notice-approved-by <SlackUID>` sends the
  notices that run still owes (deferred, failed, or confirmed by a later reconcile). It too
  exits non-zero while any notice is still owed (a deferred one goes on the next UTC day);
  escalate to #clio_devops if it keeps failing.
- **Preview:** `python3 $S notice-preview --plan <plan_run>` renders every user's notice
  without sending.
- **Dependency:** the gate's `takeback-notice` campaign (credit-trust-caroline-t06, #1239):
  its `--validate` reports the per-day cap with exit 3. A real send also needs the gate's
  `TAKEBACK_COPY_APPROVED` lock flipped (Fable copy GO + captain). Until then `--validate`
  refuses every notice (exit 1), so `apply` withholds every set as `notice_refused` and
  removes nothing: no removal without its notice. `notice-preview` still renders the copy.

### Live exclusion sources fail closed

`plan` and `apply` read them every run: `--proof-on-file` (default
`/var/lib/credit-trust/proof-on-file.json`, env `CREDIT_RETRO_PROOF_ON_FILE`),
`--org-affiliation` (default `/var/lib/credit-trust/org-affiliation.json`, env
`CREDIT_RETRO_ORG_AFFILIATION`), `--verify-ledger` (Caroline's send ledger) and
`--doc-submitted`. The hand-set `excluded` flags stay, but they were a 2026-10-16 snapshot:
a user who sends a document after a deferred day keeps the role.
- proof-on-file missing, unreadable, `generated_at` older than 3 hours or more than 5 minutes in
  the future, or a required part unusable (`scripts/credit_review/proof_parts.py`, the same rule
  as the verify notes: `core`, `cs-intercom` and `cs-gmail` must each be present, not
  flagged `stale`/`missing`, with their OWN fresh timezone-aware `generated_at`; `core` has no `stale` key, so its
  stamp is its freshness), or any other part flagged stale/missing, or a half-written export
  (`users` not the distinct user ids in `entries[]`, or any malformed entry); or the send ledger or doc
  manifest unreadable: `plan` skips every row as `proof_source_unavailable` and `apply`
  refuses before any execute. An unusable `cs-gmail` (documents emailed to support@) holds
  everyone: a snapshot of who emailed support@ cannot cover mail sent after it.
- proof-on-file, the send ledger or the doc manifest malformed (wrong shape): same as
  unreadable.
  A send ledger without Caroline's `verify_messages` table (for example one holding only the
  decider's tables), or missing any of its `verify_ledger.READER_COLUMNS`, counts as malformed;
  every deploy creates it (schema: `verify-request-notes.md` → Operate), so its absence means
  that deploy step failed. "Cannot check proof" is never "no proof" (Fable v3; contract test
  `test_send_ledger_without_verify_messages_removes_nothing`).
- org-affiliation is the credit-trust export, schema `org-affiliation/v1` (H-DevOps
  `scripts/credit-trust-exports/org-affiliation/README.md`, published hourly at :23):
  `users{id: {verdict, coverage, evidence[]}}` and `held{id: {reason}}`. Its consumer rule
  applies here:
  - file missing, unreadable, not `org-affiliation/v1`, malformed, `generated_at` older than
    2 hours or more than 5 minutes in the future: every row `affiliation_source_unavailable`,
    and `apply` refuses before any execute;
  - a user absent from `users`, or listed in `held`, is UNKNOWN: that does NOT stop the run
    (firstmate 021), `plan` skips the user's would-be-removed rows as `affiliation_unknown`
    and `apply` withholds the user's whole set; every other user's set goes ahead;
  - a per-row take-back is allowed only on `coverage: full` with `none` or
    `claimed_unverified`. Any other coverage (`labels_only`, or missing) means the user's
    publisher / major-label links were not all checked, so `none` there is not proof of no
    affiliation: `plan` skips the user's would-be-removed rows as `affiliation_partial` and
    `apply` withholds the user's whole set (it does not stop the run). The plan records
    `coverage`. The priority input below is what gives the take-back users full coverage.
- **Priority input:** before staging, write the users about to be acted on to node-8
  `/var/lib/credit-trust/inputs/org-affiliation-priority-credit-retro-exec-r1.json` as
  `{"user_ids": [...]}`, so the next hourly export checks them fully (every row and the login
  profile, `coverage: full`). On 2026-10-18 it holds the four take-back users
  (150514, 161128, 182594, 197122).
- Every skip is in the ledger with its reason; no email is written there.

### Published-roster take-back: Big Boy only (captain 2026-10-22 20:40Z, firstmate 047/048)

The captain's "big boy go" (Fable's `big-boy-audit-1022.md`, ruling step b) covers ONE profile,
`576e3c2d` (user 1387162), and adds one evidence class for it, `published_roster`.

- **The role may be multi-person** (Engineer, Assistant Engineer). It is removed only when a LIVE
  Spotify/Tidal credit lists the track's holders of that role family and the claimant is not among
  them: live verdict `OTHERS_ONLY` (or `CONTRADICTED`).
- **The allowlist is `takeback.ROSTER_CLAIMANTS`, the pair (profile `576e3c2d`, user 1387162).**
  The same profile under another user's request, and every other profile, stays one-person-only,
  and `load_manifest` refuses a multi-person row without it.
- **His whole engineering team is checked (firstmate 051).** The gate also reads the track's
  unfiltered raw credits. If any trusted source credits him in ANY engineering family (engineer,
  assistant, mix, remix, master, immersive mix/master, remaster), by name or raw-profile link, the row is
  refused as `claimant_on_engineering_team`. For example, Tidal listing him as Mixing Engineer keeps
  his Engineer row. This applies to EVERY row of the allowlisted pair, his one-person
  `trusted_dsp_only` Mixing rows included (firstmate 055): if Tidal later lists him as Recording or
  Mastering Engineer on Main Attraction, its Mixing row is held too, though Chris Godbey still holds
  Mixing.
- **Never touched:** a role no trusted source publishes (`UNVERIFIABLE`), or one a trusted source
  credits to the claimant (`CONFIRMED`). The absence of a credit is not a contradiction.
- **Notice and stage body:** it reads like `trusted_dsp_only` (the DSP label and the DSP track URL,
  with the public page Fable cited as `corroboration`). The stage evidence line says
  `evidence_class=published_roster`.
- **The approval set states its basis (firstmate 052).** For roster rows the set's `reason` begins
  with `takeback.ROSTER_BASIS` (captain 2026-10-22 "big boy go": a live Spotify/Tidal credit lists
  the engineering holders, and the claimant is not among them nor on any engineering-family role of
  the track). A set that also holds one-person rows states both bases. Each row's ledger
  `approval_ref` cites its own `decision`, which a roster row must carry.
- **Manifest:** `manifests/takeback-bigboy-r1.jsonl`, batch 1: 8 role lines on 6 requests. `plan`,
  `stage`, `apply`, `notice-preview` and `notify` take it with `--manifest` (the default is
  `takeback-r1.jsonl`).
  - 2 Mixing contradicted by Tidal.
  - 5 Engineer and 1 Assistant Engineer where Spotify/Tidal publish other holders.
  - The audit's other contradicted roles that no trusted source publishes are not in it.

**Proof on file, cleared only by a named human's answer on the credit-trust board (captain 013,
firstmate 048/051).** A document on file blocks the row. A manifest row carries only a POINTER,
`proof_check = {"notice_id": ..., "ask_id": "proof"}`. `load_manifest` refuses a row that carries
`proof_cleared` or any other clearance field, or a `proof_check` naming any ask other than `proof`
(a notice's veto ask never clears a document): an agent can write the manifest, so it never holds
the answer.
- Only a row of the allowlisted pair (`ROSTER_CLAIMANTS`) can be cleared, one-person rows such as
  Big Boy's two `trusted_dsp_only` Mixing rows included (firstmate 053). Every row of any other
  profile or user with a proof-on-file entry stays `proof_on_file:<kind>`, whatever the manifest
  says.
- `plan` and the `apply` re-check read `GET /api/notices` from the board
  (`credit_retro/board.py`). They send the agent token `CREDIT_TRUST_BOARD_AGENT_TOKEN` from
  `/etc/hydra/credit-trust-board.env` in the `X-Credit-Trust-Token` header, never in the URL. The
  host resolves as in `credit-digest-dm.sh`: `credit-trust-board.monitoring.svc.cluster.local:3000`,
  through kube-dns when the host resolver does not know it. Overrides: `CREDIT_RETRO_BOARD_ENV`,
  `_HOST`, `_PORT`, `_IP`, `CREDIT_RETRO_KUBE_DNS`.
- The row clears only when all of these hold:
  - the notice exists and is open (a closed, expired or not-open notice clears nothing: the board
    refuses new answers on it, so a later `yes` could not block again);
  - the LATEST answer to the ask (answers are append-only) is `no`, meaning the document covers
    none of the credits;
  - that answer is by a reviewer in `takeback.PROOF_REVIEWERS` (`jan@muso.ai` only);
  - the notice body names the row as `` `<request_id>:<role>` `` (the full request id and the role,
    in backticks, verbatim). The notice lists every row it clears, so a later manifest cannot
    reuse it for a row Jan never saw;
  - the notice body quotes EVERY live proof-on-file entry for the request and the user as
    `<source>:<ref>:<kind>` (e.g. `intercom:255336:human_approved_after_doc`). A changed entry
    (another kind or source) or a new one blocks again.
- **Fail closed.** A missing token, a read error or a non-200 answer holds the row, with the error
  in `before["proof_check_error"]`. A notice that does not clear it gives the reason in
  `before["proof_not_cleared"]`. A cleared row records
  `before["proof_cleared"] = {notice_id, ask_id, by, at, choice, refs}`.
- Big Boy has one entry, Intercom 255336 (2024-07-23, before every claim). The notice is not posted
  yet, so the manifest carries no `proof_check`, and every row stays held until it does.

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

**Total before the captain 013 exclusion: 417 users (141 paying), 2,069 requests / 5,124
role credits listed, plus 36 account asks; after it: 219 users (46 paying).** Waves (before
the exclusion): W-01 and W-02 (200 a day, paid first, then big tracks), W-03 17 users.
With `--editing-min-pop 60` (big tracks only) the total is 361 users (123 paying). Firstmate's
target was ~300-350; the choice of mid (30) vs big (60) is the lever.

**Who is NOT asked:** 25,746 requests from 1,888 users. These are the small unverifiable
claims, the big-unverifiable WATCH rows, small unverifiable editing claims, and ordinary
small accounts. They are left alone and written to `<run>/unverified-internal.jsonl`
(request ids only), the basis for the internal unverified flag on the board / valuation.

**Rules:**
- **Never ask anyone who already submitted a document** (captain 013, verbatim: "make sure
  you arent asking for things from users that already submitted documents and we approved.
  dont piss anyoen off"). `manifests/doc-submitted-r1.json` (user ids only, checked
  2026-10-16) lists 198 users with an Intercom attachment in any conversation or an
  identity/upload document in the verifications table, approved or pending, and the
  requests a human (jan@/nick@) approved. `waves.select` drops those users from every ask
  (rows, velocity and editing-burst account asks) and drops
  those requests. `index.json` reports `doc_submitted.before` / `.after` (417 users / 141
  paying -> 219 / 46). Once a `credit_proofs` table exists, its users join the list. When in
  doubt, don't send.
- **At most one message per user.** Rows and account asks are merged into one payload
  (`account_asks[]` is a section).
- **The take-back notice is a removed user's only message** (firstmate 016). A user with a
  `sent` take-back notice in any apply run is in no wave for 30 days after it, and a user
  still owed a notice (deferred, failed, or confirmed by a later reconcile) is in none
  either; `index.json` counts them under `takeback_notice_quiet_users`. No wave restates a
  removal: a role removed by ANY apply run on the take-back manifest (the canary, the full
  run, re-runs after a stop) and not re-added by a revert/restore is never listed or asked
  about again. `index.json` lists those runs under `apply_runs`.
- **Never re-ask someone who sent proof.** `prepare-waves --verify-ledger` drops every
  request already covered by a proof-tagged note. With live reads it also skips accounts
  that ever sent proof (`skip_already_sent_proof`) or already got a past-credit ask
  (`skip_already_asked`). If the send ledger is absent or not mounted, nothing is proven
  safe: every payload is marked `send_ledger_unavailable` (not sendable) and the index says
  `send_ledger: UNAVAILABLE`.
- **Nothing is sent** before Fable's copy GO and the merged send tool.
- **`send-check` immediately before EVERY send (firstmate 018).** A payload is prepared
  days before it goes out, and a take-back notice, a proof or an ask can land in between.
  The sender runs `python3 $S send-check --file <payload.json> --doc-submitted <list>` right before each POST
  and sends only on exit 0. There is no batch form: a wave dir checked ahead of time
  could hold a dropped user and still read green. It re-reads, at
  that moment: the 30-day take-back quiet window and users still owed a notice (this
  ledger), proof-tagged notes, proof senders and past-credit asks (`--verify-ledger`), and
  the doc-submitted list (`--doc-submitted`). That list must be rebuilt from the same
  sources (Intercom attachments in any conversation, the verifications table, human
  approvals) before sending: its `generated_at` must be at most 3 hours old (and not more
  than 5 minutes in the future: a future stamp never reads as fresh). An untagged
  document a user attached after the list was built is in no other source. The committed
  `manifests/doc-submitted-r1.json` has no `generated_at`, so it never clears a send. A failing payload is rewritten in place with
  `status: dropped_at_send_check` and the reason (exit 1) and is never sent. A passing one
  is rewritten with its credits filtered (proof-covered, human-approved and removed roles
  go). Exit 2 means it could not check (no ledger, an unreadable send ledger, or a
  doc-submitted list that is unreadable, has no `generated_at`, is older than 3 hours or is
  future-dated):
  nothing is sent and no file is touched.

The editing selection comes from `manifests/editing-ask-r1.json`. It was built from the
live trusted-credit check on 2026-10-16: 3,837 rows. The burst accounts' whole-profile
sample is 8 tracks each, and every non-burst editing row was checked.

`python3 $S prepare-waves [--apply-run <apply_run>] [--per-day 200]` writes one payload per
user to `<state-dir>/waves/<run_id>/<wave>/user-<id>.json` (mode 0600) and an `index.json`.
`--apply-run` only selects the take-back manifest that run used (and refuses if it changed
since); without it, `--takeback` names the manifest.
- **W-01..W-nn**: every ASKED user, `--per-day` users a day from 10-16. Paid users come
  first, then by the user's biggest current track, then by credit count. There is no T-01
  take-back wave any more: the removal is announced only by the notice `apply` sends.

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
- no follow-up: the payload is the user's one past-credit message (send-check drops anyone
  already asked);
- `flag_unverified_after` (day 30, internal flag only);
- `on_silence`: the credit stays, flagged unverified internally, never removed;
- `proof_channel` (Intercom now, email when E-IN lands);
- `credits_stay_visible: true`.

Online reads (the default) fill in the account email from the credit requests themselves,
refresh titles, and drop credits that are no longer approved. A user whose live read fails
is written with status `live_read_error` and is not sendable (counted under
`not_sendable`); prepare again when the API answers. `--offline` skips Muso entirely.

Templates are in `retro-drafts/`. The past-credit grouped ask and the account ask are new
drafts that still need Fable's review; the take-back notice has Fable's copy edits applied,
the old take-back wave note is retired, and the follow-up draft is not scheduled. None of
them carries a removal date.

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
