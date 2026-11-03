# Merge verifier: is this profile merge safe, from evidence (SHADOW)

> Captain, 2026-10-28 01:5xZ: "…the ability to properly verify credits profile and profile merge[s]". Hard limits: shadow only. The verifier computes verdicts and logs them with evidence. It does not approve, decline, merge or message anyone. Going live is the captain's call, on measured precision.

Code: `scripts/merge_verify/` and `scripts/merge-verify.py`. Tests: `python3 scripts/tests/test_merge_verify.py` (in PR Validation). Eval: `verifier-eval-v1` ([verifier-eval.md](./verifier-eval.md)) scores its log.

For each **open** `action:profile-merge` ticket (ClickUp User Requests, status type neither closed nor done) it outputs:
- one verdict, with the evidence it was decided on;
- for every duplicate that is `eligible`, the **exact command** a named human would run, plus the call the requester's own self-serve session would make (and core's dry check for it).

It never runs either one.

## What it can never do

- **No executor.** It has no merge, unmerge, decide, ticket-tag, reply or ledger write anywhere in its call graph. The tests check this with the AST (no `subprocess`, no merge, tag or reply route), and the Intercom client refuses anything that is not a conversation GET or one of the two search endpoints. Core reads go through `credit_review.admin.AdminClient`, which is GET-only, and replica reads are Trino `SELECT`s.
- **No confirmer.** The command carries `--confirmed-by <captain handle>` as a literal placeholder. No agent confirmer exists (fable-decider and caroline-autonomous are both gone), and the verifier never picks one.
- **Reconcile stays verify-only.** The verifier reads `profile_merges`. It never settles a row.
- **One write: its own audit store**, `/var/lib/hydra-merge-verify/merge-verify.sqlite` (0600, append-only). It has one `mv_verdicts` row per (run, ticket, duplicate) holding:
  - the rule version, the verdict, the reasons and the command;
  - the full facts and their sha256, so any verdict can be re-derived.
- **Reversible.** Nothing reads the store, so reverting means ignoring a run, or deleting the file.
- **Kill switch.** If `/etc/hydra/merge-verify.disabled` exists, `run` exits 0 and reads nothing. `MERGE_VERIFY_DISABLED_FILE` overrides the path.
- **Not scheduled.** No cron or CronJob runs it. A run is a one-shot by an operator. A scheduled shadow run, as a T5 pod job, is the captain's and the T5 lane's call.

## The rule (`rules.decide`, pure)

Ticket stages are checked in order, and the first that applies sets the verdict. Stages 1 to 7 follow profile-merge-ops-m1's 235-ticket re-read (`data/profile-merge-ops-m1/merge-states-1028.md`), with core's guards applied where core is stricter.

| # | check | verdict | eval |
|---|---|---|---|
| 0 | a fact section the stage needs was not read | `unknown` | UNKNOWN |
| 1 | no keep or no duplicate, or an id not in the catalog (`includeDeleted=true`) | `needs_ids` | WAIT |
| 2 | every duplicate ends on the keep along **verified** ledger rows | `already_merged` | WAIT (no-op) |
| 3 | a profile on the fraud watchlist, or the requester on the watchlist or the fraud-lens holds | `held_watchlist` | WAIT |
| 4 | an organisation profile | `refused:ORG_PROFILE` | DECLINE |
| 5 | a profile without a processed claim (pending listed apart) | `needs_claim` | WAIT |
| 6 | processed claims in two workspaces or by two accounts, or another account's open claim | `refused:OPEN_CLAIM` | DECLINE |
| 7 | a duplicate is another account's login profile or confirmed presented primary (tier confirmed or high). This is core's `findLoginOrPrimaryLosers`: it is **exempt when the keep is that same account's own** login or primary | `refused:LOGIN_OR_PRIMARY_LOSER` | DECLINE |

Then each remaining duplicate is checked on its own, again in order:

| # | check | verdict |
|---|---|---|
| 8 | a `profile_merges` row on the pair is in flight, or the keep was itself merged away | `wait:merge_in_flight` |
| 9 | the person type differs | `refused:TYPE_MISMATCH` |
| 10 | a populated duplicate would fold into the requester's empty login shell (core `EMPTY_SHELL_MAIN`) | `refused:EMPTY_SHELL_MAIN` |
| 11 | a paid seat held by a workspace that is not the requester's (core `PAID_SEAT`; core's `PAYING_SUB` predicate). The requester's claim workspaces stand in for core's "workspaces the caller manages"; core's dry check decides the edge | `refused:PAID_SEAT` |
| 12 | **owner confirmation** is missing. It needs a conversation that is the requester's own: the claimant account's email, exactly one Intercom contact with that email, exactly that one contact on the conversation. In it, the requester's own parts must name the keep **and** this duplicate | `wait:owner_thread` |
| 13 | **the big / common / flagged guard** trips: popularity ≥ 60, the keep has fewer credits than the duplicate (direction), a claim with screening risk flags, or another same-name profile that is claimed or holds credits. That census is the catalog search walked **to exhaustion** (50 per page, ranked, so a conflict can sit on any page); a page that cannot be read, or a result set still full at 1,000, is `unknown`, never "nobody else" | `needs_human:big_profile` / `direction` / `flagged_claim` / `common_name` |
| 14 | **same person on the DSPs** is not shown. It needs one Spotify or Tidal artist identity present on **both** profiles. A name never counts | `needs_evidence:same_person` |
| 15 | everything holds | `eligible`, with the command |

A ticket is `eligible` only when every duplicate is. It is `partial` when some are; the commands are listed for those, one loser per call, because core's legacy route refuses more than one claimed loser. Otherwise the most protective duplicate verdict names the ticket.

**UNKNOWN never approves.** Every fact that was not read is None, and the rule answers `unknown`, never "nothing there". `fresh_read` records whether every read was made in this run. A frozen snapshot is never fresh: a replay can measure `eligible`, but marks it measurement-only.

Core re-checks its own guards at execution. Both `POST /admin/profiles/merge` and the self-serve `POST /api/v4/user/profiles/merge` do (the latter answers 409 `SELF_MERGE_SWITCHED_OFF` while the flag is off). An `eligible` here is **evidence for a human**, not a replacement for core's dry verify endpoint (`POST /admin/self-merge-requests/verify`, self-merge-core-b1). That endpoint stays the single truth for the self-serve switch.

Known gaps, each recorded on the row and never guessed:
- **Claim screening flags.** The replica's `claiming` has no `screeningRiskFlags` or `screeningRecommendation` columns; they exist only on core's primary. The flag guard therefore uses them only when a source carries them. An eligible row says "screening flags are not on the replica; core re-checks them at execution".
- **A second same-person basis** is not built yet: related names plus a trusted recording credited to both on Spotify and Tidal in the same run (core's `name_and_trusted_shared_recording`). Until it is, those duplicates read `needs_evidence:same_person`, and that list is its work list.

## Measured

**1. The m1 regression (frozen, committed).** `scripts/merge_verify/sets/m1-1028.jsonl.gz` holds the 235 open tickets of m1's re-read (`.measure` pulls of 2026-10-27 20:5xZ). It carries ids, counts, DSP artist ids and booleans only: no names, no emails. `merge-verify.py replay --agreement` reproduces m1's state on **225/235** tickets. The 10 differences are pinned in the test:
- 9 tickets are D2 in m1's table but exempt under core's rule, because the keep is the same account's own login or primary. m1's own 08:00Z correction moves the same 9 to executable-L7. Of those 9, 3 then hit core's `EMPTY_SHELL_MAIN`;
- 1 ticket has its requester on the fraud watchlist (m1 matched profile ids only).

The snapshot has no paid-seat read, so nothing in it approves.

**2. verifier-eval-v1 (frozen merges set, 275 items).** The replay log is clean: **0 false approves, 0 guard violations, 0 false declines**. It made 70 declines, with decline precision 1.000 on the `audit` labels (core 409s). The 16 declines on `ops_classification` WAIT labels are org-profile refusals the 10-26 coarse classes had filed as no-ids or needs-claim. Binary agreement is 195/275, against 71 for merges-rules-v1 and 38 for the muso-cli gate. The 39 `A_already_merged` labels read WAIT here (a no-op, not an action), and those make up most of the remaining disagreement.

**3. Live shadow run on node-8** (2026-10-28 16:44Z, run `20261028T164419Z-2d445c`, read-only, 9 min):

- **235 open tickets**, the same count as m1's re-read. 0 `unknown` and **0 eligible**, so no command is emitted.

| ticket verdict | n | | duplicate verdict (stage 8) | n |
|---|---|---|---|---|
| needs_claim | 122 | | wait:owner_thread | 14 |
| already_merged | 26 | | needs_evidence:same_person | 5 |
| refused:LOGIN_OR_PRIMARY_LOSER | 24 | | refused:EMPTY_SHELL_MAIN | 4 |
| refused:ORG_PROFILE | 17 | | needs_human:common_name | 3 |
| needs_ids | 13 | | needs_human:direction | 3 |
| refused:OPEN_CLAIM | 12 | | needs_human:big_profile | 2 |
| per-duplicate (8 owner thread, 3 common name, 3 same person, 3 empty shell, 2 big, 1 direction, 1 paid seat) | 21 | | refused:PAID_SEAT | 1 |

- **m1's 12 executable-L7 rows (the ones with commands), each blocked by a named protection:**
  - big profile: 869dd731b (pop 77) and 869dn3vp3 (pop 64);
  - direction: 869djgdvr; on 869ddxu62, direction and a claimed same-name profile;
  - no owner thread naming both profiles: 869dje62e, 869dgh8jx, 869ddx1ne;
  - no Spotify or Tidal identity shared by both profiles: 869dm4g1j, 869djbnd6, 869dgnk6h;
  - **paid seat**: 869de1uru. The duplicate is a paid seat of a second workspace the requester holds no claim in. No earlier list caught this.
- **The live log scored by verifier-eval-v1** (frozen 275-item merges set) is CLEAN:
  - 0 false approves, 0 guard violations, 0 false declines.
  - Decline precision is 1.000 on the `audit` labels. Binary agreement is 218/275 (0.793); the eval set is from 10-26, so 24 of its tickets have since closed.
  - The 12 `audit` 409 labels it does not decline are exactly the core-exempt tickets above. Those labels are adjudication candidates for the eval set.

## Running

```bash
# node-8, gateway env (CLICKUP_API_KEY / MUSOAI_INTERCOM_TOKEN / MUSO_ADMIN_* from /etc/openclaw/main.env)
set -a; . /etc/openclaw/main.env; set +a
python3 /opt/hydra/scripts/merge-verify.py run --eval-log /var/lib/hydra/verifier-eval/inbox/merges/merge-verify.jsonl
python3 /opt/hydra/scripts/merge-verify.py summary
python3 /opt/hydra/scripts/merge-verify.py replay --agreement          # the frozen m1 set, offline
python3 /opt/hydra/scripts/merge-verify.py replay --measure <m1 .measure dir> --states <merge-states-1028.md> --write-set <out.jsonl.gz>
```

A full run over about 235 open tickets makes:
- about 6 Trino SELECTs per 300 profiles;
- one catalog GET per 50 profiles (a failed chunk is retried in tens);
- one catalog search per duplicate name;
- Intercom contact and conversation reads for each claimant account.

The eval log (`--eval-log`) is in verifier-eval's recorded format. Ids are `<ticket>` and `<ticket>:<loser 8-hex>`; verdicts are `eligible`, `refused:<SLUG>`, `queued_review` or `UNKNOWN`.
