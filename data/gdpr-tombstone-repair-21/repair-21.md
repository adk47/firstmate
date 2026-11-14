# Repair report: the `DELETE /admin/profile/:id` hides (read-only, measured 2026-11-04T23:2xZ)

**Ids only, no names.** A data subject's display name is deliberately not recorded in this report or its capture
file: `scripts/gdpr_pipeline/hide_batch.py:8` — "Ids only in files and PR text: no requester names". The
`Reproduce` command below re-derives any name from the live admin API when a person needs it.

Lane: **gdpr-tombstone-repair-21** (firstmate), spec item 5. Evidence:
`data/gdpr-tombstone-repair-21/capture-2026-11-04.jsonl` (one JSON object per id) produced by
`data/gdpr-tombstone-repair-21/collect-21.py`, which runs **on node-8** and writes nothing
(GETs, `SELECT`s, file reads; no `muso` write, no register update, no PR).

## What I measured, and where the numbers come from

| field | source |
|---|---|
| `deletes[]` | `/var/log/muso-ops/audit.jsonl` — the muso-CLI audit rows for `DELETE /api/v3/admin/profile/<id>`, `dry_run=false`. This is the **authoritative** record of the 21/24 (the older `bulk-destructive-audit.jsonl` stops at 2026-10-21 and would have shown **zero**, which is why the census's "21" needed a re-measure) |
| `tombstone.creditCount_before` | `GET /admin/profile?includeDeleted=true&ids=<id>` — the admin tombstone survives the delete and keeps the denormalised `creditCount` (and `rawProfiles`) as they were when it was deleted |
| `served_now` | `SELECT count(*) FROM postgresql_catalog.public.matvw_profile_credit WHERE profile_id = '<id>'` (served associations; control on a live 2-credit profile returns 1 track row) |
| `register[]` | `/var/lib/hydra-gdpr/erasure.sqlite` (read-only URI), the page's own verdict |
| `hidden_lists` | `gdpr_pipeline.sources.hidden_lists()` — `HIDDEN_ENTITY_IDS` **and** `LEGAL_HIDDEN_ENTITY_IDS` |
| `profile_api` / `public_page` | `https://api.muso.ai/api/w/v3/profile/<id>` and `https://muso.ai/profile/<id>` |

## The finding the count changes

The census said **21** profile ids. The audit log shows **24** live profile deletes from 2026-10-22 onward, all
`requester=jan@muso.ai`, `service=muso-cli` (i.e. `muso … api DELETE /admin/profile/<id>` from the deleted
`profile-visibility-management` skill), 17 of them via `--confirmed-by jan` / a god-mode self-approve on Jan's own
message ts:

| # | deleted (UTC) | id | register row(s) | admin tombstone | served credits before → now | both hide lists |
|---|---|---|---|---|---|---|
| 1 | 10-22 14:34:06 | `7127c801…` | #34 `GONE` (removed_outside_process) | deleted 10-22, by `operations` | 9 → **0** | no |
| 2 | 10-22 14:34:12 | `12519691…` | #34 `GONE` | deleted, `operations` | 9 → **0** | no |
| 3 | 10-22 14:34:16 | `f6178264…` | #34 `GONE` | deleted, `operations` | 23 → **0** | no |
| 4 | 10-22 19:01:15 | `0092c828…` | #36 `ALREADY_HIDDEN` | deleted, `operations` | 1 → **0** | **yes** (410) |
| 5 | 10-23 15:04:21 | `8cf938bc…` | #7 `GONE` | deleted, `operations` | 2 → **0** | no |
| 6 | 10-26 14:00:11 | `61f4087f…` | #22/#127 `ALREADY_HIDDEN` | deleted, `operations` | 13 → **0** | **yes** (410) |
| 7 | 10-26 14:00:16 | `8e60c590…` | #22/#127 `ALREADY_HIDDEN` | deleted, `operations` | 13 → **0** | **yes** (410) |
| 8 | 10-26 14:03:12 | `fe69b1a2…` | #34 `GONE` | deleted, `operations` | 8 → **0** | no |
| 9 | 10-26 14:03:19 | `8d96238f…` | #34 `GONE` | deleted, `operations` | 25 → **0** | no |
| 10 | 10-26 15:05:38 | `61b02cb9…` | #50/#124 `GONE` | deleted, `operations` | 28 → **0** | no |
| 11 | 10-27 18:28:00 | `799687e8…` | #113 `GONE` | deleted, `operations` | 48 → **0** | no |
| 12 | 10-27 18:34:42 | `a4b530fb…` | #120 `GONE` | deleted, `operations` | 14 → **0** | no |
| 13 | 10-27 18:34:46 | `0bbbde19…` | #120 `GONE` | deleted, `operations` | 10 → **0** | no |
| 14 | 10-27 18:34:53 | `cb330e1c…` | #120 `GONE` | deleted, `operations` | 11 → **0** | no |
| 15 | 10-27 19:08:16 | `603e75d6…` | #118 `GONE` | deleted, `operations` | 2 → **0** | no |
| 16 | 10-28 17:49:45 | `88e759e2…` | #144 `GONE` | deleted, `operations` | 0 → 0 | no |
| 17 | 10-30 16:01:52 | `0d898512…` | **NO ROW** | deleted, `operations` | 20 → **0** | no |
| 18 | 11-02 18:03:47 | `153a79ef…` | #18/#75/#252 `ALREADY_HIDDEN` | deleted, `operations` | 22 → **0** | **yes** (410) |
| 19 | 11-02 18:03:55 | `3a98fb32…` | #18/#75/#252 `ALREADY_HIDDEN` | deleted, `operations` | 10 → **0** | **yes** (410) |
| 20 | 11-04 16:17:55 | `fc31a861…` | #377 **`PASS_C`** | deleted, `operations` | 1 → **0** | no |
| 21 | 11-04 18:11:26 | `7871c617…` | #126 **`LEGAL_HIDE_FIRST`** / #246 `GONE` | deleted, `operations` | 13 → **0** | no |
| 22 | 11-04 18:11:28 | `43efa0ca…` | #126 **`LEGAL_HIDE_FIRST`** | deleted, `operations` | 2 → **0** | no |
| 23 | 11-04 18:11:30 | `c5d687e6…` | #126 **`LEGAL_HIDE_FIRST`** | deleted, `operations` | 2 → **0** | no |
| 24 | 11-04 20:36:08 | `a6ad1088…` | **NO ROW** | deleted, `operations` | **431 → 0** | no |

Every one of the 24 answers **404** on the profile API and on the canonical public page, **except** the five ids that
are also on both hide lists, which answer **410** (the correct, reversible hide response — those five are the only
ones a visitor can distinguish from a deleted profile).

### 1. `removed_outside_process` is the register's name for this, and it is accurate

13 of the 24 sit on a row whose page verdict is `GONE` ("the catalog and the public page both answer 404 and this id
was never …"): #7, #34, #50, #113, #118, #120, #124, #144, #246 — exactly the flag the census reported. It reads as a
statement about the customer, and it is: our own bot did it, outside the hide process, with no list entry and no
inverse. That flag is the reason these rows keep waiting for a person to say what happened.

### 2. The five "consistent" ids are consistent about the HIDE, not about the credits

`0092c828`, `61f4087f`, `8e60c590`, `153a79ef`, `3a98fb32` are on **both** lists and answer **410** — the reversible
hide path worked for them (some were added after the DELETE). Their served associations are still 0, so the hide is
consistent while the credit purge is not undone by it.

### 3. Two ids have NO register row at all

`0d898512-1981-466a-885a-ca77b803ba37` (10-30) and
`a6ad1088-b402-4f7d-ba82-4a8b946a3d9b` (11-04 20:36). Neither ever reached the register, so nothing is
tracking a confirmation letter or a hide for them, and the customer's request is invisible to every pass.

**0d898512 gets a row** (spec item 5). It cannot be filed by the deployed tree: `slack-ops` is a channel this PR adds
(`CANDIDATE_CHANNELS`), and the deployed `/opt/hydra/scripts/gdpr-pipeline.py` rejects it. The prepared candidate is
`data/gdpr-tombstone-repair-21/0d898512-candidate.json`; after this PR deploys, the row lands with

```
python3 scripts/ops_intake/hide.py --apply \
  --requester-id U038BM16T7W --message-ts 1793376053.796469 --channel C0APB2CMM7C
```

There is no ask-text argument: the ids and the class are read from that Slack message's own body.

Note what the class will be: the requester's stated reason on that ask was **"tracks were removed from spotify"**, so
it is a **catalog takedown (`dmca_takedown`)** by the mapping in this lane, not a GDPR erasure. Filing it as a GDPR
erasure would tell the customer we erased their data when we removed tracks.

### 4. `fc31a861` is the sharpest single case

Deleted 11-04 16:17Z — and register row **#377 decides the page `PASS_C`**, i.e. the pipeline had already decided this
page could be hidden through the reversible path. The DELETE ran first, and it is the one case where a *future*
legitimate hide would have hidden the page without destroying the credits.

### 5. The three ids on row #126 are a captain decision, not a repair

`7871c617`, `43efa0ca`, `c5d687e6` sit on row **#126, `LEGAL_HIDE_FIRST`** — a legal threat, which the register
deliberately leaves to the captain (the same row's page was excluded from the routine hide batch on purpose, and
gdpr-pipeline-g1 verified that exclusion on the live store). They were DELETEd 11-04 18:11Z, one minute after the
18:10Z ask, i.e. **before** any decision. The captain owns both the legal reply and what to do about a hide that
preceded his call.

## needs-decision (for the captain)

**Restore from the tombstone, or accept?** Every one of the 24 ids has **0** rows in the served association view
(`matvw_profile_credit`) today; the 23 that had credits carry **717** of them on their admin tombstones
(`creditCount_before`, the count as it stood when each was deleted; control check: a live 2-credit profile returns a
row, so a 0 is the association being gone, not the query failing). The tombstone row survives with its denormalised
`creditCount` and `rawProfiles` (the `a6ad1088` tombstone still shows tidal artist `18077607` and `creditCount: 431`), so the
profile *record* is intact; the served associations are what is gone.

I did **not** measure whether restore is technically possible (that needs the raw DSP credit rows for these profiles,
keyed by their raw profile ids, not by the muso profile id) and I did not write anything. The two live questions:

- `a6ad1088`, **431 → 0**, escalated by #credit-verification at 20:37Z. Restore, or accept?
- the other 22 ids with associations lost (largest: `799687e8` 48→0, `61b02cb9` 28→0, `8d96238f` 25→0,
  `f6178264` 23→0, `153a79ef` 22→0, `0d898512` 20→0). Restore as a class, or accept as a class?

## What already stops a recurrence

- Both wrappers now refuse `DELETE /admin/profile/:id` (`MUSO_REMOVAL_NO_SELF_APPROVE`) — the wrapper
  (`muso-admin-api.sh`, both copies) and the `muso` CLI hook (`scripts/muso-prewrite-hook.sh`).
- The workspace skill that taught it is deleted, and `scripts/check-skill-drift.sh` Pass 4 fails any doctrine that
  names the soft-delete as a hide path.
- The ops ask now has a coded path (`scripts/ops_intake/hide.py`) that files the register row, gets the pipeline's
  identity verdict, and prepares the reversible PR pair.

## Reproduce

```
cd <worktree>
ssh -J root@135.148.169.37 root@10.0.0.8 'set -a; . /etc/openclaw/main.env; set +a; python3 -' \
  < data/gdpr-tombstone-repair-21/collect-21.py > /tmp/capture.jsonl
```

Read-only end to end: the collector never calls a write endpoint and never touches the register.
