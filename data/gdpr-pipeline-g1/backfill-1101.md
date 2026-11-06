# GDPR erasure register — backfill table (2026-11-06 02:15Z)

The machine register the pipeline actually acts on, generated from the live store
(`/var/lib/hydra-gdpr/erasure.sqlite`, read-only copy) with `gdpr-pipeline.py report`. This is the
deliverable the brief asks for: **id, received, due, identity verdict, action** for every open request,
before any hide PR.

## Counts

**These are a snapshot, not a live figure.** The tick adds rows every hour, so the numbers below were true when this
file was written and will drift. This table was regenerated on 2026-11-06 02:15Z; the first cut (2026-11-05) read
383 open / 168 past due, and the three rows the tick added since are the reason the figures move. For the current
register, read the store (or re-run the generator):

```
set -a; . /etc/openclaw/main.env; set +a
/opt/hydra/scripts/gdpr-pipeline.py report          # the same table, from the live store
```

| | |
|---|---|
| open requests | **386** |
| past the 30-day statutory date | **174** |
| letters ever sent (`erasure_sends` rows) | **0** |
| confirmed | **1** |
| hidden (`hidden_at` set) | **29** |

By channel: `intercom` 275, `notices` 47, `support` 36, `legal` 24, `register` 4

By identity verdict: `ASK_LINK` 122, `GONE` 74, `JAN_REVIEW` 40, `UNKNOWN` 37, `ACCESS` 25, `ASK_IDENTITY` 23, `ALREADY_HIDDEN` 18, `PASS_A` 16, `LEGAL_HIDE_FIRST` 7, `PASS_C` 7, `DMCA_REVIEW` 6, `JAN_BIGNAME` 5, `PASS_B` 4, `NOT_ERASURE` 2

## What the verdicts mean for the next action

- `PASS_A/B/C/D` — identity established by code; the row is hide-eligible and owes a confirmation.
- `ASK_LINK` / `ASK_IDENTITY` / `ASK_AUTH` — the approved ask line is owed; a claim is ONE identity path,
  never a requirement (gdpr-ack-v2 §3).
- `GONE` — the page answers 404 in the catalog and publicly with no hide record: a person confirms what
  happened before any letter.
- `HIDDEN_PENDING` — half a hide (one of the two lists); no letter is owed, the other PR must merge.
- `ALREADY_HIDDEN` — on both lists; the confirmation is owed.
- `UNKNOWN` — a read failed or a fact was not stated; re-read next run, never assumed absent.
- `JAN_REVIEW` / `JAN_BIGNAME` / `DMCA_REVIEW` / `LEGAL_HIDE_FIRST` — a person decides.

## The table

| reg # | keys | class | received | due (30 d) | | identity verdict | basis | pages (verdict) | action |
|---|---|---|---|---|---|---|---|---|---|
| 329 | IC 45463 | legal_threat | 2025-09-20 19:54 | 2025-10-20 | PAST | ASK_LINK | - | - | ASK: link line |
| 327 | IC 215473778655376 | privacy_erasure | 2026-04-05 02:41 | 2026-05-05 | PAST | GONE | - | 09ec96ac GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 323 | IC 215473719245164 | legal_threat | 2026-04-05 18:50 | 2026-05-05 | PAST | ASK_LINK | - | - | ASK: link line |
| 56 | notices@:19d85f50b5fbea79 | privacy_erasure | 2026-04-13 08:28 | 2026-05-13 | PAST | UNKNOWN | - | dfed0379 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 318 | IC 215473921553266 | legal_threat | 2026-04-15 10:05 | 2026-05-15 | PAST | GONE | - | cd5a46d2 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 320 | IC 215474009504867 | legal_threat | 2026-04-21 17:16 | 2026-05-21 | PAST | GONE | - | be9053c5 GONE; ccfc99d1 GONE; f3c35751 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 324 | IC 215474031390936 | privacy_erasure | 2026-04-23 22:26 | 2026-05-23 | PAST | ASK_LINK | - | - | ASK: link line |
| 57 | notices@:19de989af4bc5c22 | privacy_erasure | 2026-05-02 16:33 | 2026-06-01 | PAST | GONE | - | 5189c230 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 326 | IC 215474217555085 | privacy_erasure | 2026-05-07 21:51 | 2026-06-06 | PAST | ASK_LINK | - | - | ASK: link line |
| 40 | legal@:19e1eb8f00b29bc5, notices@:19e1ac77c49d1c29 | privacy_erasure | 2026-05-12 05:53 | 2026-06-11 | PAST | UNKNOWN | - | 00dfd5d5 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 372 | IC 215471908152432 | legal_threat | 2026-05-21 12:33 | 2026-06-20 | PAST | ASK_LINK | - | - | ASK: link line |
| 58 | notices@:19e6700041d1cb7f | dmca_takedown | 2026-05-27 01:15 | 2026-06-26 | PAST | ASK_LINK | - | - | ASK: link line |
| 328 | IC 215474487546575 | privacy_erasure | 2026-05-28 19:30 | 2026-06-27 | PAST | ASK_LINK | - | - | ASK: link line |
| 364 | IC 215474371167201 | legal_threat | 2026-05-30 05:23 | 2026-06-29 | PAST | JAN_REVIEW | - | ad51d913 JAN_REVIEW | Jan: scope (non-profile page) |
| 341 | IC 215474577179841 | privacy_erasure | 2026-06-04 16:04 | 2026-07-04 | PAST | GONE | - | cd5ee048 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 363 | IC 215474535267261 | privacy_erasure | 2026-06-05 12:02 | 2026-07-05 | PAST | ASK_LINK | - | - | ASK: link line |
| 215 | CU 869dk337f | privacy_erasure | 2026-06-05 14:42 | 2026-07-05 | PAST | GONE | - | 5189c230 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 59 | notices@:19ebce066a1b12bb | privacy_erasure | 2026-06-12 17:27 | 2026-07-12 | PAST | UNKNOWN | - | 0023fca5 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 362 | IC 215474629637074 | legal_threat | 2026-06-12 19:17 | 2026-07-12 | PAST | JAN_BIGNAME | - | c2d81ed8 JAN_BIGNAME | Jan: big-name / high-credit page |
| 60 | notices@:19ebde7d9903ba76 | dmca_takedown | 2026-06-12 22:15 | 2026-07-12 | PAST | JAN_REVIEW | - | 0351f725 DMCA_REVIEW; 14da7f14 DMCA_REVIEW; 54386c84 DMCA_REVIEW; 60c23050 DMCA_REVIEW; 64c668bf DMCA_REVIEW; 72f5c741 DMCA_REVIEW; 73c49aa9 DMCA_REVIEW; a62c3c72 DMCA_REVIEW; c38db6a5 DMCA_REVIEW; d7f652f8 DMCA_REVIEW; ea7434db DMCA_REVIEW; ee899c69 DMCA_REVIEW; 313ec67d JAN_REVIEW; 3b984797 JAN_REVIEW; 3f9f4665 JAN_REVIEW; 58862e8f JAN_REVIEW; 5911b441 JAN_REVIEW; 5e3d681b JAN_REVIEW; 676c2c9c JAN_REVIEW; d7dfc8a4 JAN_REVIEW; ec68ac19 JAN_REVIEW | Jan: scope (non-profile page) |
| 214 | CU 869dp8bxn | privacy_erasure | 2026-06-13 11:51 | 2026-07-13 | PAST | ASK_LINK | - | - | ASK: link line |
| 213 | CU 869dph46x | privacy_erasure | 2026-06-14 22:29 | 2026-07-14 | PAST | ASK_LINK | - | - | ASK: link line |
| 237 | CU 869dpj0fr | privacy_access | 2026-06-15 02:10 | 2026-07-15 | PAST | ACCESS | - | ab8fe39f | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 61 | notices@:19ecafccf5096b89 | legal_threat | 2026-06-15 11:13 | 2026-07-15 | PAST | UNKNOWN | - | 507ee681 UNKNOWN; b977db9d UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 236 | CU 869dqtq42 | privacy_access | 2026-06-17 00:49 | 2026-07-17 | PAST | ACCESS | - | - | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 272 | IC 215474744429231, IC 215476412181821 | privacy_erasure | 2026-06-17 18:39 | 2026-07-17 | PAST | PASS_A | A | 01c45665 PASS_A | hide batch |
| 322 | IC 215474836302826 | privacy_erasure | 2026-06-25 00:20 | 2026-07-25 | PAST | ASK_IDENTITY | - | 759c34a2 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 330 | IC 215474840632530 | privacy_erasure | 2026-06-25 10:54 | 2026-07-25 | PAST | ASK_LINK | - | - | ASK: link line |
| 331 | IC 215474840805867 | privacy_erasure | 2026-06-25 11:09 | 2026-07-25 | PAST | ASK_LINK | - | - | ASK: link line |
| 361 | IC 215474692454481 | legal_threat | 2026-06-25 11:41 | 2026-07-25 | PAST | ASK_LINK | - | - | ASK: link line |
| 235 | CU 869dz886q, IC 215474939720100 | privacy_access | 2026-07-02 20:14 | 2026-08-01 | PAST | ACCESS | - | - | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 62 | notices@:19f38abed12ef2b3 | privacy_erasure | 2026-07-06 18:23 | 2026-08-05 | PAST | UNKNOWN | - | a335bcbf UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 360 | IC 215474979995070 | privacy_erasure | 2026-07-06 18:23 | 2026-08-05 | PAST | GONE | - | a335bcbf GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 358 | IC 215475009212070 | privacy_erasure | 2026-07-08 15:55 | 2026-08-07 | PAST | ASK_IDENTITY | - | 91f23bc0 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 63 | notices@:19f4b4639b0a49d8 | privacy_erasure | 2026-07-10 09:05 | 2026-08-09 | PAST | UNKNOWN | - | 25a962e9 UNKNOWN; 270343e9 UNKNOWN; a978baf2 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 325 | IC 215475030681990 | privacy_erasure | 2026-07-10 09:05 | 2026-08-09 | PAST | GONE | - | 25a962e9 GONE; 270343e9 GONE; a978baf2 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 212 | CU 869e3hwjf, IC 215475049448900 | dmca_takedown | 2026-07-12 06:50 | 2026-08-11 | PAST | GONE | - | fb0a8812 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 359 | IC 215475062774567 | privacy_erasure | 2026-07-13 14:18 | 2026-08-12 | PAST | ASK_LINK | - | - | ASK: link line |
| 64 | notices@:19f62363199de8e3 | legal_threat | 2026-07-14 19:58 | 2026-08-13 | PAST | ASK_LINK | - | - | ASK: link line |
| 365 | IC 215472634481802 | privacy_erasure | 2026-07-15 16:51 | 2026-08-14 | PAST | GONE | - | 06190ae1 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 356 | IC 215475109353707 | legal_threat | 2026-07-16 19:34 | 2026-08-15 | PAST | ASK_LINK | - | - | ASK: link line |
| 342 | IC 215475148766168 | legal_threat | 2026-07-19 15:02 | 2026-08-18 | PAST | ASK_LINK | - | - | ASK: link line |
| 357 | IC 215475124710554 | privacy_erasure | 2026-07-20 16:06 | 2026-08-19 | PAST | ASK_LINK | - | - | ASK: link line |
| 321 | IC 215475180897794 | privacy_erasure | 2026-07-22 01:02 | 2026-08-21 | PAST | JAN_REVIEW | - | 17f69a59 GONE; b91e2ef7 GONE; f8cb6ad6 GONE; 69b99dd2 JAN_REVIEW | Jan: scope (non-profile page) |
| 211 | CU 869e86x9k, IC 215475190631753 | privacy_erasure | 2026-07-22 17:39 | 2026-08-21 | PAST | JAN_REVIEW | A | 0a7ec8c1 JAN_REVIEW; 1821f1ac JAN_REVIEW; 29288f5a JAN_REVIEW; 2ff0c905 JAN_REVIEW; 3677d3b2 JAN_REVIEW; 57102859 JAN_REVIEW; 644c5b1f JAN_REVIEW; 66ba39e8 JAN_REVIEW; 6e592682 JAN_REVIEW; 7bfb77cc JAN_REVIEW; 828d9707 JAN_REVIEW; 9da68adc JAN_REVIEW; bcb3fb6a JAN_REVIEW; beefbeab JAN_REVIEW; f0b0b094 JAN_REVIEW; f398c456 JAN_REVIEW; 11e93933 PASS_A | Jan: scope (non-profile page) |
| 319 | IC 215475269349138 | privacy_erasure | 2026-07-29 07:46 | 2026-08-28 | PAST | ASK_LINK | - | - | ASK: link line |
| 210 | CU 869eb356x, IC 215475271568557 | privacy_erasure | 2026-07-29 12:28 | 2026-08-28 | PAST | ASK_LINK | - | - | ASK: link line |
| 335 | IC 215475273028402 | privacy_erasure | 2026-07-29 13:25 | 2026-08-28 | PAST | JAN_REVIEW | - | abfa2d10 JAN_REVIEW; 0708125e ASK_IDENTITY; b91e2ef7 GONE | Jan: scope (non-profile page) |
| 354 | IC 215475314043321 | privacy_erasure | 2026-08-01 04:32 | 2026-08-31 | PAST | ASK_LINK | - | - | ASK: link line |
| 355 | IC 215475325530645 | privacy_erasure | 2026-08-02 16:41 | 2026-09-01 | PAST | GONE | - | 04dd5222 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 337 | IC 215475357613948 | legal_threat | 2026-08-04 19:59 | 2026-09-03 | PAST | ASK_LINK | - | - | ASK: link line |
| 336 | IC 215475390033486 | legal_threat | 2026-08-07 00:10 | 2026-09-06 | PAST | ASK_LINK | - | - | ASK: link line |
| 65 | notices@:19fe04d7777dc816 | privacy_erasure | 2026-08-08 07:36 | 2026-09-07 | PAST | UNKNOWN | - | 9670e23f UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 234 | CU 869eg7td4, IC 215475424776708 | privacy_access | 2026-08-10 12:18 | 2026-09-09 | PAST | ACCESS | - | 9acfe392 | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 209 | CU 869ejeezz, IC 215475505866743 | privacy_erasure | 2026-08-16 10:01 | 2026-09-15 | PAST | ASK_IDENTITY | - | ad383faa ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 233 | CU 869ekhqkr, IC 215475537577149 | privacy_access | 2026-08-18 15:25 | 2026-09-17 | PAST | ACCESS | - | 045cdbec | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 352 | IC 215475580892308 | privacy_erasure | 2026-08-21 09:38 | 2026-09-20 | PAST | ASK_LINK | - | - | ASK: link line |
| 353 | IC 215475602706946 | privacy_erasure | 2026-08-23 00:08 | 2026-09-22 | PAST | GONE | - | b76dcbec GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 351 | IC 215475609005038 | privacy_erasure | 2026-08-23 18:47 | 2026-09-22 | PAST | ASK_IDENTITY | - | 85a7c011 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 15 | legal@:1a0333cf993345bb, reg 15 | privacy_erasure | 2026-08-24 00:00 | 2026-09-23 | PAST | JAN_REVIEW | - | c18163e7 JAN_REVIEW | Jan: scope (non-profile page) |
| 16 | legal@:1a03cf817af65dcd, reg 16 | privacy_erasure | 2026-08-26 00:00 | 2026-09-25 | PAST | ALREADY_HIDDEN | - | f8b294d0 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 66 | notices@:1a03e868545b1218 | legal_threat | 2026-08-26 14:43 | 2026-09-25 | PAST | UNKNOWN | - | 507ee681 UNKNOWN; b977db9d UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 366 | IC 215475653044023 | legal_threat | 2026-08-26 14:43 | 2026-09-25 | PAST | GONE | - | 507ee681 GONE; b977db9d GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 338 | IC 215475667393912 | legal_threat | 2026-08-27 09:13 | 2026-09-26 | PAST | JAN_BIGNAME | - | 658062ff JAN_BIGNAME; dbd836a9 JAN_BIGNAME | Jan: big-name / high-credit page |
| 348 | IC 215475710870469 | privacy_erasure | 2026-08-30 16:18 | 2026-09-29 | PAST | GONE | - | 2cbb0135 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 208 | CU 869eryndc, IC 215475719420655 | privacy_erasure | 2026-08-31 10:16 | 2026-09-30 | PAST | GONE | - | 69fa2876 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 28 | notices@:1a061d72d0dc9ff8, reg 28 | dmca_takedown | 2026-09-02 00:00 | 2026-10-02 | PAST | DMCA_REVIEW | - | 947f783f DMCA_REVIEW; 3cd92fda ALREADY_HIDDEN; b51234aa ALREADY_HIDDEN | copyright review (claim-first) |
| 67 | notices@:1a062273f746fd07 | privacy_erasure | 2026-09-02 12:45 | 2026-10-02 | PAST | UNKNOWN | - | 0daa2bb7 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 370 | IC 215475769014734 | privacy_erasure | 2026-09-03 04:53 | 2026-10-03 | PAST | GONE | - | 60f20728 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 349 | IC 215475769017890 | privacy_erasure | 2026-09-03 04:54 | 2026-10-03 | PAST | GONE | - | 60f20728 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 350 | IC 215475787748643 | privacy_erasure | 2026-09-04 07:41 | 2026-10-04 | PAST | ALREADY_HIDDEN | - | f8b294d0 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 68 | notices@:1a06b5df09191540 | privacy_erasure | 2026-09-04 07:41 | 2026-10-04 | PAST | UNKNOWN | - | e3109ff5 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 339 | IC 215475791604209 | legal_threat | 2026-09-04 14:46 | 2026-10-04 | PAST | ASK_LINK | - | - | ASK: link line |
| 17 | legal@:1a073f2a93c21a6e, reg 17 | privacy_erasure | 2026-09-05 23:41 | 2026-10-05 | PAST | ALREADY_HIDDEN | - | 132d0c7f ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 69 | notices@:1a07a4456d9dee2d | privacy_erasure | 2026-09-07 05:07 | 2026-10-07 | PAST | ASK_LINK | - | - | ASK: link line |
| 207 | CU 869eycuqj, IC 215475830659338 | privacy_erasure | 2026-09-07 17:25 | 2026-10-07 | PAST | ASK_LINK | - | - | ASK: link line |
| 228 | CU 869favgu5, IC 215475834113372 | privacy_access | 2026-09-07 20:42 | 2026-10-07 | PAST | ACCESS | - | - | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 18 | notices@:1a082d0c033671a3, reg 18 | legal_threat | 2026-09-08 00:00 | 2026-10-08 | PAST | JAN_REVIEW | - | 3d00e2cf JAN_REVIEW; 153a79ef ALREADY_HIDDEN; 3a98fb32 ALREADY_HIDDEN | Jan: scope (non-profile page) |
| 29 | notices@:1a081f6b6b6978f1, reg 29 | dmca_takedown | 2026-09-08 00:00 | 2026-10-08 | PAST | JAN_REVIEW | - | 41e1de13 JAN_REVIEW; 000a601a ALREADY_HIDDEN; 059fa29c ALREADY_HIDDEN; 07470984 ALREADY_HIDDEN; 109141d8 ALREADY_HIDDEN; 1b45e11d ALREADY_HIDDEN; 357fbf56 ALREADY_HIDDEN; 3b20c7c9 ALREADY_HIDDEN; 424afc66 ALREADY_HIDDEN; 51b71dc6 ALREADY_HIDDEN; 6541852c ALREADY_HIDDEN; 6a7be543 ALREADY_HIDDEN; 6e57932e ALREADY_HIDDEN; 6f54e503 ALREADY_HIDDEN; 88a02104 ALREADY_HIDDEN; 8fd0231a ALREADY_HIDDEN; 9486243b ALREADY_HIDDEN; a063c0db ALREADY_HIDDEN; ab60cf4f ALREADY_HIDDEN; b55476ea ALREADY_HIDDEN; bf55238d ALREADY_HIDDEN; c074e3a2 ALREADY_HIDDEN; c3a8f3cd ALREADY_HIDDEN; dd1a8cb3 ALREADY_HIDDEN; e9de203b ALREADY_HIDDEN; f0ad8f9f ALREADY_HIDDEN | Jan: scope (non-profile page) |
| 206 | CU 869eyvpeb, IC 215475840841215 | privacy_erasure | 2026-09-08 11:15 | 2026-10-08 | PAST | ASK_LINK | - | - | ASK: link line |
| 70 | notices@:1a082f20955800b6 | privacy_erasure | 2026-09-08 21:34 | 2026-10-08 | PAST | UNKNOWN | - | d9151390 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 41 | legal@:1a085cb1ff8cc37f | privacy_erasure | 2026-09-09 10:51 | 2026-10-09 | PAST | ASK_LINK | - | - | ASK: link line |
| 9 | CU 869fk2mja, IC 215475857940898, reg 9 | dmca_takedown | 2026-09-09 10:51 | 2026-10-09 | PAST | JAN_REVIEW | - | 08235bd1 JAN_REVIEW; 5884396e JAN_REVIEW; 5debcd7c JAN_REVIEW; 897bd213 JAN_REVIEW; a7360012 JAN_REVIEW; ba5cf580 JAN_REVIEW; dad6f412 JAN_REVIEW; fbb0edbd JAN_REVIEW; 88309597 DMCA_REVIEW; 8fa3d85d DMCA_REVIEW; 9869de84 DMCA_REVIEW; c416d1a2 DMCA_REVIEW; ee3dbeb6 DMCA_REVIEW; 1307257e JAN_REVIEW; 3ca473db JAN_REVIEW; 870b6f85 JAN_REVIEW; 9ccf42b3 JAN_REVIEW; a23b727c JAN_REVIEW; cbcdb873 JAN_REVIEW; ed066fae JAN_REVIEW; f780c5c0 JAN_REVIEW; fedcb028 JAN_REVIEW | Jan: scope (non-profile page) |
| 71 | notices@:1a0886707687e1ef | privacy_erasure | 2026-09-09 23:00 | 2026-10-09 | PAST | UNKNOWN | - | 0eabe142 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 347 | IC 215475892004167 | privacy_erasure | 2026-09-11 00:23 | 2026-10-11 | PAST | GONE | - | 30e8d97d GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 344 | IC 215475927056674 | privacy_erasure | 2026-09-14 11:18 | 2026-10-14 | PAST | ASK_IDENTITY | - | b4acb899 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 368 | IC 215475934585496 | privacy_erasure | 2026-09-14 18:11 | 2026-10-14 | PAST | GONE | - | 1bcdb6b8 GONE; 887fccae GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 369 | IC 215475938568765 | privacy_erasure | 2026-09-15 20:03 | 2026-10-15 | PAST | JAN_REVIEW | A+B | 927cc08c JAN_REVIEW; 2be757a6 PASS_A; ddf02528 PASS_B | Jan: scope (non-profile page) |
| 42 | legal@:1a0a773d9d795e7b | privacy_erasure | 2026-09-15 23:42 | 2026-10-15 | PAST | UNKNOWN | - | db063ec3 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 345 | IC 215475964604672 | privacy_erasure | 2026-09-16 13:51 | 2026-10-16 | PAST | GONE | - | 5fead85d GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 231 | CU 869f8dpkp, IC 215475965109147 | privacy_access | 2026-09-16 14:22 | 2026-10-16 | PAST | ACCESS | - | - | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 72 | notices@:1a0aae72f37f6e9c | dmca_takedown | 2026-09-16 15:47 | 2026-10-16 | PAST | ASK_LINK | - | - | ASK: link line |
| 346 | IC 215475967066927 | privacy_erasure | 2026-09-16 16:39 | 2026-10-16 | PAST | PASS_A | A | 279d7ea6 PASS_A | hide batch |
| 203 | CU 869f3y9yj, IC 215475968237385, IC 215475991455935 | legal_threat | 2026-09-16 17:59 | 2026-10-16 | PAST | GONE | - | e1bff550 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 205 | CU 869f3p3n1, IC 215475985162611 | privacy_erasure | 2026-09-17 19:46 | 2026-10-17 | PAST | PASS_A | A | 0aa9fcb4 PASS_A | hide batch |
| 73 | notices@:1a0b0e7feffa2dc4 | legal_threat | 2026-09-17 19:46 | 2026-10-17 | PAST | ASK_LINK | - | - | ASK: link line |
| 367 | IC 215475985153553 | legal_threat | 2026-09-17 19:53 | 2026-10-17 | PAST | LEGAL_HIDE_FIRST | legal | 115e4e15 LEGAL_HIDE_FIRST; 2377a097 LEGAL_HIDE_FIRST; 7880266a ALREADY_HIDDEN; a5dc7ed1 LEGAL_HIDE_FIRST; b225d8c7 ALREADY_HIDDEN; e51f994a LEGAL_HIDE_FIRST; f0d8db2f LEGAL_HIDE_FIRST; f5398792 LEGAL_HIDE_FIRST; fc5f1214 ALREADY_HIDDEN | captain: legal threat, hide first (hide-batch --include-legal), identity after |
| 204 | CU 869f3qdtn, IC 215475987595452 | privacy_erasure | 2026-09-17 23:30 | 2026-10-17 | PAST | PASS_A | A | 0090898f PASS_A | hide batch |
| 43 | legal@:1a0b404bec68c986, notices@:1a0b404c14167145 | legal_threat | 2026-09-18 10:16 | 2026-10-18 | PAST | GONE | - | e1bff550 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 371 | IC 215475991808139 | privacy_erasure | 2026-09-18 10:55 | 2026-10-18 | PAST | GONE | - | 2fb06715 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 74 | notices@:1a0be20a6d0760a4 | privacy_erasure | 2026-09-20 09:23 | 2026-10-20 | PAST | ASK_LINK | - | - | ASK: link line |
| 44 | legal@:1a0be5b715b369d5, notices@:1a0be5b705b1f388 | privacy_erasure | 2026-09-20 10:27 | 2026-10-20 | PAST | UNKNOWN | - | 9ad7c7f3 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 202 | CU 869f4n5gf, IC 215476020986965 | privacy_erasure | 2026-09-21 00:04 | 2026-10-21 | PAST | ASK_IDENTITY | - | 04899213 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 201 | CU 869f4npyx, IC 215476022503954 | privacy_erasure | 2026-09-21 04:20 | 2026-10-21 | PAST | GONE | A | 0416f089 GONE; 7fc48083 PASS_A | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 45 | legal@:1a0c43d517193f56 | legal_threat | 2026-09-21 13:52 | 2026-10-21 | PAST | LEGAL_HIDE_FIRST | legal | 623e49af LEGAL_HIDE_FIRST | captain: legal threat, hide first (hide-batch --include-legal), identity after |
| 200 | CU 869f584ez, IC 215476035526486 | privacy_erasure | 2026-09-21 19:37 | 2026-10-21 | PAST | ASK_IDENTITY | - | 454baecc ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 199 | CU 869f5aawf, IC 215476042143399 | dmca_takedown | 2026-09-22 01:37 | 2026-10-22 | PAST | ASK_LINK | - | - | ASK: link line |
| 332 | IC 215476050390082 | privacy_erasure | 2026-09-22 14:50 | 2026-10-22 | PAST | ASK_LINK | - | - | ASK: link line |
| 198 | CU 869f5qxva, IC 215476051150924 | dmca_takedown | 2026-09-22 15:14 | 2026-10-22 | PAST | GONE | A | 18e3887c PASS_A; e9d6eea8 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 334 | IC 215476057950173 | privacy_erasure | 2026-09-22 21:24 | 2026-10-22 | PAST | JAN_REVIEW | A | b3852e92 PASS_A; 6fec252a JAN_REVIEW | Jan: scope (non-profile page) |
| 19 | legal@:1a0cd8b4b062d803, reg 19 | privacy_erasure | 2026-09-23 00:00 | 2026-10-23 | PAST | ALREADY_HIDDEN | - | ef2a4bbe ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 242 | legal@:1a0cd8b4b062d803:again:2026-09-23T09:14:00Z, reg 19:again:2026-09-23T09:14:00Z | privacy_erasure | 2026-09-23 09:14 | 2026-10-23 | PAST | UNKNOWN | - | ef2a4bbe UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 195 | CU 869f7hk3p, IC 215476069845281 | privacy_erasure | 2026-09-23 15:57 | 2026-10-23 | PAST | PASS_A | A | 3e199354 PASS_A; 995203e3 PASS_A | hide batch |
| 232 | CU 869f6btax, IC 215476071746122 | privacy_access | 2026-09-23 17:55 | 2026-10-23 | PAST | ACCESS | - | - | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 171 | CU 869f6jmv2, CU 869fbqh15, IC 215476077474779 | dmca_takedown | 2026-09-24 00:09 | 2026-10-24 | PAST | JAN_REVIEW | - | 51641140 GONE; 90e148d9 GONE; 00e2c8b1 JAN_REVIEW; 06bbc23c JAN_REVIEW; 09619ec7 JAN_REVIEW; 12648829 JAN_REVIEW; 13fe3752 JAN_REVIEW; 140056f5 JAN_REVIEW; 1dfdb4d6 JAN_REVIEW; 2d610155 JAN_REVIEW; 33f351b6 JAN_REVIEW; 3d418eeb JAN_REVIEW; 4205fb92 JAN_REVIEW; 48784556 JAN_REVIEW; 590886d0 JAN_REVIEW; 5ccb48a0 JAN_REVIEW; 64c4ff52 JAN_REVIEW; 681183a7 JAN_REVIEW; 8946202d JAN_REVIEW; 8d01d33e JAN_REVIEW; 92798cf4 JAN_REVIEW; 9d42e9ba JAN_REVIEW; a1586cd8 JAN_REVIEW; a26d2eab JAN_REVIEW; aaa87a72 JAN_REVIEW; abfeda67 JAN_REVIEW; adfb80e4 JAN_REVIEW; c0c2558a JAN_REVIEW; ca3eac4f JAN_REVIEW; d48089eb JAN_REVIEW; d64b5050 JAN_REVIEW; d93c45c6 JAN_REVIEW; dcd34212 JAN_REVIEW; e593f265 JAN_REVIEW; edf541ca JAN_REVIEW; fa4c65a1 JAN_REVIEW | Jan: scope (non-profile page) |
| 333 | IC 215476079293453 | privacy_erasure | 2026-09-24 05:01 | 2026-10-24 | PAST | GONE | - | e6b04f64 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 75 | notices@:1a0d2e0693be65a2, notices@:1a0dd3fb1d198e76 | legal_threat | 2026-09-24 10:04 | 2026-10-24 | PAST | JAN_REVIEW | - | 3d00e2cf JAN_REVIEW; 153a79ef ALREADY_HIDDEN; 3a98fb32 ALREADY_HIDDEN | Jan: scope (non-profile page) |
| 197 | CU 869f73kfe, IC 215476092759328 | privacy_erasure | 2026-09-24 22:45 | 2026-10-24 | PAST | JAN_REVIEW | - | 9a907293 JAN_REVIEW; 763460dd ASK_IDENTITY; 8893de2e GONE | Jan: scope (non-profile page) |
| 46 | legal@:1a0d965aa18d4ebf | privacy_erasure | 2026-09-25 16:28 | 2026-10-25 | PAST | GONE | - | e5ebb84c GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 196 | CU 869f7hb72, IC 215476105541266 | privacy_erasure | 2026-09-25 16:31 | 2026-10-25 | PAST | GONE | - | b1aa52ab GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 194 | CU 869f7m7ur, IC 215476112695993 | privacy_erasure | 2026-09-26 04:15 | 2026-10-26 | PAST | GONE | - | 812fef3a GONE; d69c1005 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 76 | notices@:1a0dcc291af7bc24 | privacy_erasure | 2026-09-26 08:08 | 2026-10-26 | PAST | UNKNOWN | - | b100af8e UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 193 | CU 869f7n1u8, IC 215476113768456 | privacy_erasure | 2026-09-26 08:34 | 2026-10-26 | PAST | GONE | A | ba76d9ed GONE; c90a5cf8 PASS_A | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 12 | CU 1amvh555fah, CU 869f7pf5p, CU 869fbfnrz, CU 869fg2f1w, CU 869fk47u5, IC 215476114962780, IC 215476423551746, reg 12 | dmca_takedown | 2026-09-26 12:47 | 2026-10-26 | PAST | JAN_REVIEW | A | 260b115c GONE; 34ef09c5 GONE; 44530206 PASS_A; 91fba1fa GONE; 0a7d9c00 JAN_REVIEW; 1bb533c9 JAN_REVIEW; 23b11b35 JAN_REVIEW; 2e0e666e JAN_REVIEW; 407a5926 JAN_REVIEW; 4e332761 JAN_REVIEW; 511df363 JAN_REVIEW; 5292d635 JAN_REVIEW; 57abb3b2 JAN_REVIEW; 59dedbd9 JAN_REVIEW; 6a8f6136 JAN_REVIEW; 7279ed7f JAN_REVIEW; 810238b5 JAN_REVIEW; 89bb9e4b JAN_REVIEW; 945e5b3d JAN_REVIEW; aae29ae8 JAN_REVIEW; b8290f3c JAN_REVIEW; b9f2c507 JAN_REVIEW; c1c68cdf JAN_REVIEW; c53c0ba4 JAN_REVIEW; c58560c5 JAN_REVIEW; cd645eb3 JAN_REVIEW; dc948f78 JAN_REVIEW; e26324fe JAN_REVIEW; fcf9888e JAN_REVIEW | Jan: scope (non-profile page) |
| 20 | notices@:1a0e431adf90d179, reg 20 | privacy_erasure | 2026-09-27 00:00 | 2026-10-27 | PAST | UNKNOWN | - | 328e43b6 UNKNOWN; 6027afe5 ALREADY_HIDDEN; dba83bef UNKNOWN; f4beb005 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 192 | CU 869f7xmx8, IC 215476127057928 | privacy_erasure | 2026-09-27 17:41 | 2026-10-27 | PAST | GONE | - | d349890c GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 47 | legal@:1a0e571b646acb86 | privacy_erasure | 2026-09-28 00:36 | 2026-10-28 | PAST | UNKNOWN | - | c7b1c2ea UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 167 | CU 869f7zw51, CU 869fca0r1, IC 215476130939818 | privacy_erasure | 2026-09-28 02:51 | 2026-10-28 | PAST | GONE | - | f97d7b11 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 77 | notices@:1a0e64d34c167a9e | privacy_erasure | 2026-09-28 04:36 | 2026-10-28 | PAST | UNKNOWN | - | ce684087 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 343 | IC 215476131373328 | privacy_erasure | 2026-09-28 04:37 | 2026-10-28 | PAST | ASK_LINK | - | - | ASK: link line |
| 48 | legal@:1a0e68920888edab | privacy_erasure | 2026-09-28 05:42 | 2026-10-28 | PAST | UNKNOWN | - | d49ef594 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 191 | CU 869f8ggb0, IC 215476139025627 | privacy_erasure | 2026-09-28 15:25 | 2026-10-28 | PAST | GONE | A | 96d2a8c3 GONE; a54f593f PASS_A | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 190 | CU 869f8jeep, IC 215476141122476 | privacy_erasure | 2026-09-28 17:18 | 2026-10-28 | PAST | GONE | A | a8790188 PASS_A; d1e7b4e7 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 189 | CU 869f8k3j3, IC 215476142736218 | dmca_takedown | 2026-09-28 18:36 | 2026-10-28 | PAST | GONE | - | 0bd412ec GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 78 | notices@:1a0e9f484683bcfc | legal_threat | 2026-09-28 21:38 | 2026-10-28 | PAST | JAN_REVIEW | - | d349890c GONE; 56d3a3e4 JAN_REVIEW; 6db45ee1 JAN_REVIEW; e5e08c4a JAN_REVIEW; ee94bb5b JAN_REVIEW | Jan: scope (non-profile page) |
| 188 | CU 869f8mfe4, IC 215476145669299 | legal_threat | 2026-09-28 21:38 | 2026-10-28 | PAST | JAN_REVIEW | - | d349890c GONE; 56d3a3e4 JAN_REVIEW; 6db45ee1 JAN_REVIEW; e5e08c4a JAN_REVIEW; ee94bb5b JAN_REVIEW | Jan: scope (non-profile page) |
| 187 | CU 869f8n2ft, IC 215476147050298 | dmca_takedown | 2026-09-29 00:08 | 2026-10-29 | PAST | GONE | - | 98364b79 GONE; e22603aa DMCA_REVIEW | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 49 | legal@:1a0eb6ac7198977a | privacy_erasure | 2026-09-29 04:27 | 2026-10-29 | PAST | GONE | - | a090d672 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 186 | CU 869f8nmfu, IC 215476148351327 | privacy_erasure | 2026-09-29 04:27 | 2026-10-29 | PAST | GONE | - | a090d672 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 185 | CU 869f8npbh, IC 215476148496872 | not_erasure | 2026-09-29 04:55 | 2026-10-29 | PAST | NOT_ERASURE | - | - | not an erasure request (misfiled ticket): no hide, no letter |
| 184 | CU 869f99fh7, IC 215476159721667 | privacy_erasure | 2026-09-29 19:46 | 2026-10-29 | PAST | GONE | A | 6ba45d2a GONE; 70dd575f PASS_A; bd66cdcc GONE; bf1c9ec8 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 183 | CU 869f99yv5, IC 215476160492600 | privacy_erasure | 2026-09-29 20:16 | 2026-10-29 | PAST | GONE | - | a9e2704f GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 182 | CU 869f9b6q9, IC 215476163894415 | privacy_erasure | 2026-09-29 23:33 | 2026-10-29 | PAST | GONE | - | f9bd5a29 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 79 | notices@:1a0f291f6d81fd3d | privacy_erasure | 2026-09-30 13:47 | 2026-10-30 | PAST | ASK_LINK | - | - | ASK: link line |
| 230 | CU 869f9xpux, IC 215476174888100 | privacy_access | 2026-09-30 16:14 | 2026-10-30 | PAST | ACCESS | - | - | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 229 | CU 869fa2db8, IC 215476181004950 | privacy_access | 2026-09-30 23:07 | 2026-10-30 | PAST | ACCESS | - | c5457e13 | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 181 | CU 869fa3nmk, IC 215476183811763 | privacy_erasure | 2026-10-01 05:05 | 2026-10-31 | PAST | GONE | - | 5bab037a GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 180 | CU 869famp97, IC 215476189726158 | privacy_erasure | 2026-10-01 14:51 | 2026-10-31 | PAST | GONE | - | cdba65a9 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 179 | CU 869farkcv, IC 215476195187845 | privacy_erasure | 2026-10-01 18:46 | 2026-10-31 | PAST | GONE | - | 9fc3c804 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 50 | legal@:1a0f9637f28593f5 | privacy_erasure | 2026-10-01 21:33 | 2026-10-31 | PAST | GONE | - | 61b02cb9 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 227 | CU 869fbanmw, IC 215476219865586 | privacy_access | 2026-10-02 19:32 | 2026-11-01 | PAST | ACCESS | - | 7edf4a67, f6c2d2d0 | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 178 | CU 869fbb22e, IC 215476220760547 | cancel_intent_mentions_deletion | 2026-10-02 20:51 | 2026-11-01 | PAST | JAN_REVIEW | - | - | Jan: cancel-intent ticket that mentions deletion (read the customer's words) |
| 177 | CU 869fbccvj, IC 215476222853734 | dmca_takedown | 2026-10-03 02:54 | 2026-11-02 | PAST | GONE | - | da8d61df GONE; dcf5f461 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 176 | CU 869fbcxb9, IC 215476223815936 | privacy_erasure | 2026-10-03 07:12 | 2026-11-02 | PAST | JAN_REVIEW | - | 2547286b GONE; 7cd6a9b5 JAN_REVIEW | Jan: scope (non-profile page) |
| 175 | CU 869fbffx8, IC 215476226996309 | privacy_erasure | 2026-10-03 16:36 | 2026-11-02 | PAST | PASS_A | A | 2f223327 PASS_A | hide batch |
| 174 | CU 869fbfhxy, IC 215476227075584 | privacy_erasure | 2026-10-03 16:51 | 2026-11-02 | PAST | GONE | - | 002162ab GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 173 | CU 869fbg98f, IC 215476228747617 | dmca_takedown | 2026-10-03 19:59 | 2026-11-02 | PAST | GONE | - | 18065fde GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 80 | notices@:1a103e93cdc30bb1 | privacy_erasure | 2026-10-03 22:36 | 2026-11-02 | PAST | UNKNOWN | - | 222084df UNKNOWN; 95ae1a59 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 172 | CU 869fbh3u2, IC 215476229626248 | privacy_erasure | 2026-10-03 23:22 | 2026-11-02 | PAST | PASS_A | A | d77e5652 PASS_A | hide batch |
| 317 | IC 215476238795636 | privacy_erasure | 2026-10-04 21:18 | 2026-11-03 | PAST | ASK_LINK | - | - | ASK: link line |
| 21 | notices@:1a10db97c7d1b870, reg 21 | privacy_erasure | 2026-10-05 00:00 | 2026-11-04 | PAST | ALREADY_HIDDEN | - | 8d0f69e8 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 170 | CU 869fbv1xw, IC 215476243574372 | privacy_erasure | 2026-10-05 07:56 | 2026-11-04 | PAST | GONE | - | 284e8817 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 169 | CU 869fbvfdx, IC 215476243743678 | privacy_erasure | 2026-10-05 08:12 | 2026-11-04 | PAST | JAN_REVIEW | - | 9611980e ASK_IDENTITY; 576968ae JAN_REVIEW | Jan: scope (non-profile page) |
| 168 | CU 869fc3y0b, IC 215476246785464 | legal_threat | 2026-10-05 13:13 | 2026-11-04 | PAST | GONE | legal | e21ba33a LEGAL_HIDE_FIRST; fb561ebf GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 1 | CU 869fcxq64, IC 215476105456852, IC 215476269953303, reg 1 | privacy_erasure | 2026-10-06 00:00 | 2026-11-05 | PAST | JAN_REVIEW | - | 9e7c6b3f JAN_REVIEW; 8cab7e3b GONE; e5ebb84c GONE; 0c73d3f5 JAN_REVIEW; 22529b2c JAN_REVIEW; 5dbc5482 JAN_REVIEW | Jan: scope (non-profile page) |
| 22 | notices@:1a1113544c50137b, reg 22 | privacy_erasure | 2026-10-06 00:00 | 2026-11-05 | PAST | ALREADY_HIDDEN | - | 61f4087f ALREADY_HIDDEN; 8e60c590 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 316 | IC 215476260488011 | privacy_erasure | 2026-10-06 06:29 | 2026-11-05 | PAST | ASK_LINK | - | - | ASK: link line |
| 166 | CU 869fcg63m, IC 215476261197820 | privacy_erasure | 2026-10-06 08:08 | 2026-11-05 | PAST | GONE | - | 62cb6abc GONE; fa708933 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 165 | CU 869fcuve7, IC 215476265766935 | not_erasure | 2026-10-06 15:12 | 2026-11-05 | PAST | NOT_ERASURE | - | - | not an erasure request (misfiled ticket): no hide, no letter |
| 51 | legal@:1a11226ad6bedf88 | privacy_erasure | 2026-10-06 16:57 | 2026-11-05 | PAST | ALREADY_HIDDEN | - | d5a2d6b1 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 164 | CU 869fcwkyn, IC 215476267924708 | privacy_erasure | 2026-10-06 17:25 | 2026-11-05 | PAST | PASS_A | A | 5e8296ca PASS_A; a5097660 PASS_A | hide batch |
| 314 | IC 215476270704617 | legal_threat | 2026-10-06 19:24 | 2026-11-05 | PAST | ASK_LINK | - | - | ASK: link line |
| 2 | CU 869fdvuzj, IC 215476287244669, reg 2 | legal_threat | 2026-10-07 00:00 | 2026-11-06 | PAST | JAN_REVIEW | legal | e65b5115 JAN_REVIEW; 222084df LEGAL_HIDE_FIRST; 95ae1a59 LEGAL_HIDE_FIRST; 1fc115c2 JAN_REVIEW; 4c878ba6 JAN_REVIEW; 9ef1f807 JAN_REVIEW | Jan: scope (non-profile page) |
| 23 | legal@:1a11677c51f6533d, reg 23 | privacy_erasure | 2026-10-07 00:00 | 2026-11-06 | PAST | ASK_LINK | - | - | ASK: link line |
| 315 | IC 215476285843201 | privacy_erasure | 2026-10-07 16:40 | 2026-11-06 | <=3d | PASS_C | C | 8c20ff77 PASS_C | hide batch |
| 309 | IC 215476296433138 | privacy_erasure | 2026-10-08 09:17 | 2026-11-07 | <=3d | ASK_LINK | - | - | ASK: link line |
| 162 | CU 869feve41, IC 215476297130875 | privacy_erasure | 2026-10-08 10:35 | 2026-11-07 | <=3d | GONE | A | 08e425cb GONE; 2928007d PASS_A; 4f9fbfc0 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 220 | CU 869fe9n4d, CU 869fk2mrp, IC 215476297352889 | privacy_access | 2026-10-08 11:03 | 2026-11-07 | <=3d | ACCESS | - | a7547923 | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 163 | CU 869feekdr, IC 215476299426348 | privacy_erasure | 2026-10-08 13:36 | 2026-11-07 | <=3d | ASK_IDENTITY | - | 89934b04 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 226 | CU 869femm9w, IC 215476308934703 | privacy_access | 2026-10-08 22:15 | 2026-11-07 | <=3d | ACCESS | - | - | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 161 | CU 869ff2xyc, IC 215476323414659 | privacy_erasure | 2026-10-09 15:56 | 2026-11-08 | <=3d | GONE | - | 00dc0574 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 160 | CU 869ff3w5v | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | UNKNOWN | - | 89934b04 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 159 | CU 869ff3w69 | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | GONE | - | 08e425cb GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 154 | CU 869ff3w6n, CU 869ff3w8z, CU 869ff3wcj | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | UNKNOWN | - | a526eea0 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 158 | CU 869ff3w7f | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | UNKNOWN | - | 222084df UNKNOWN; 95ae1a59 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 157 | CU 869ff3w9g, CU 869ff3w9v | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | GONE | - | 002162ab GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 156 | CU 869ff3waa | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | UNKNOWN | - | ccb7892b UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 155 | CU 869ff3wb0 | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | JAN_REVIEW | - | 112295d4 GONE; 8eec331a JAN_REVIEW | Jan: scope (non-profile page) |
| 153 | CU 869ff3wd4 | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | GONE | - | cdba65a9 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 152 | CU 869ff3wdv | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | JAN_REVIEW | - | 9e7c6b3f JAN_REVIEW; 2a24587c GONE; 0c73d3f5 JAN_REVIEW | Jan: scope (non-profile page) |
| 151 | CU 869ff3wfk | privacy_erasure | 2026-10-09 16:57 | 2026-11-08 | <=3d | GONE | - | 3fa6d50b GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 150 | CU 1amvh555k04, CU 869ff8afu, IC 215476330310195, IC 215476407140826 | dmca_takedown | 2026-10-10 03:17 | 2026-11-09 |  | JAN_REVIEW | - | 39d2420d GONE; b8580584 DMCA_REVIEW; 809077a3 JAN_REVIEW; 9cdf115e JAN_REVIEW | Jan: scope (non-profile page) |
| 149 | CU 869ffbggm, IC 215476332696961 | privacy_erasure | 2026-10-10 11:34 | 2026-11-09 |  | GONE | A | 8ee1f3c0 GONE; ba5455c3 PASS_A | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 148 | CU 869ffctu5, IC 215476334639136 | legal_threat | 2026-10-10 15:33 | 2026-11-09 |  | LEGAL_HIDE_FIRST | legal | 4c7dd32d LEGAL_HIDE_FIRST | captain: legal threat, hide first (hide-batch --include-legal), identity after |
| 147 | CU 869ffcukj, IC 215476334663649 | privacy_erasure | 2026-10-10 15:38 | 2026-11-09 |  | GONE | - | 303867d9 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 313 | IC 215476337147956 | privacy_erasure | 2026-10-10 21:46 | 2026-11-09 |  | ASK_LINK | - | - | ASK: link line |
| 24 | notices@:1a12ae1aff824c65, reg 24 | privacy_erasure | 2026-10-11 00:00 | 2026-11-10 |  | ALREADY_HIDDEN | - | 67386664 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 146 | CU 869fffy3d, IC 215476340677484 | privacy_erasure | 2026-10-11 09:51 | 2026-11-10 |  | JAN_REVIEW | - | 950f9b73 JAN_REVIEW | Jan: scope (non-profile page) |
| 312 | IC 215476345084390 | privacy_erasure | 2026-10-11 19:16 | 2026-11-10 |  | ASK_LINK | - | - | ASK: link line |
| 145 | CU 869ffme6f, IC 215476346375387 | privacy_erasure | 2026-10-11 21:43 | 2026-11-10 |  | ASK_IDENTITY | - | 12e9a234 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 144 | CU 869fg432d, IC 215476356274043 | privacy_erasure | 2026-10-12 16:07 | 2026-11-11 |  | GONE | A | 88e759e2 GONE; ed097556 PASS_A | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 311 | IC 215476357593959 | privacy_erasure | 2026-10-12 17:23 | 2026-11-11 |  | ASK_LINK | - | - | ASK: link line |
| 143 | CU 869fg5jku, IC 215476359521088 | privacy_erasure | 2026-10-12 19:21 | 2026-11-11 |  | ASK_IDENTITY | - | 8fc69984 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 142 | CU 869fg7eek, IC 215476362520506 | dmca_takedown | 2026-10-13 00:41 | 2026-11-12 |  | GONE | - | 66ecea70 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 141 | CU 869fg7h8e, IC 215476362688002 | privacy_erasure | 2026-10-13 01:09 | 2026-11-12 |  | GONE | - | 3fa6d50b GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 52 | legal@:1a1337bcf65e0f7f | privacy_erasure | 2026-10-13 04:18 | 2026-11-12 |  | ASK_LINK | - | - | ASK: link line |
| 140 | CU 869fg7v4r, IC 215476363752814 | privacy_erasure | 2026-10-13 04:18 | 2026-11-12 |  | PASS_A | A | 542e26d7 PASS_A | hide batch |
| 310 | IC 215476367004101 | privacy_erasure | 2026-10-13 11:28 | 2026-11-12 |  | ASK_LINK | - | - | ASK: link line |
| 139 | CU 869fgn714 | privacy_erasure | 2026-10-13 14:59 | 2026-11-12 |  | ASK_IDENTITY | - | 374c1e32 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 138 | CU 869fgq65w | privacy_erasure | 2026-10-13 16:47 | 2026-11-12 |  | ASK_LINK | - | - | ASK: link line |
| 137 | CU 869fguknr, IC 215476376923936 | privacy_erasure | 2026-10-13 21:24 | 2026-11-12 |  | PASS_C | C | b47bcca5 PASS_C | hide batch |
| 136 | CU 869fgv2rd, IC 215476378170604 | dmca_takedown | 2026-10-13 22:23 | 2026-11-12 |  | JAN_REVIEW | - | 2d472fc8 GONE; 6bf066fb GONE; 6f9574cc JAN_REVIEW | Jan: scope (non-profile page) |
| 135 | CU 869fgw40q, IC 215476383077924 | privacy_erasure | 2026-10-14 04:45 | 2026-11-13 |  | GONE | - | 58ddaa79 GONE; 5984df20 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 225 | CU 869fgyrkn, IC 215476386028865 | privacy_access | 2026-10-14 08:35 | 2026-11-13 |  | ACCESS | - | 239c5600, 6c16adc3 | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 134 | CU 869fh68by, CU 869fh698h, IC 215476390826267 | privacy_erasure | 2026-10-14 14:16 | 2026-11-13 |  | GONE | - | b3919f36 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 133 | CU 869fhay7t, IC 215476398155769 | dmca_takedown | 2026-10-14 21:22 | 2026-11-13 |  | GONE | - | 0a0ab1c3 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 224 | CU 869fhbd05, IC 215476399687646 | privacy_access | 2026-10-14 23:08 | 2026-11-13 |  | ACCESS | - | 18601a1e | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 308 | IC 215476411784560 | privacy_erasure | 2026-10-15 17:29 | 2026-11-14 |  | ASK_LINK | - | - | ASK: link line |
| 223 | CU 869fhw9vm, IC 215476412723064 | privacy_access | 2026-10-15 18:34 | 2026-11-14 |  | ACCESS | - | 67a2c5f5 | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 299 | IC 215476413777315 | legal_threat | 2026-10-15 19:19 | 2026-11-14 |  | ASK_LINK | - | - | ASK: link line |
| 119 | CU 1amvh554ub2, CU 1amvh555ufk, CU 869fhxjfu, IC 215476416143081, IC 215476703808871 | privacy_erasure | 2026-10-15 21:49 | 2026-11-14 |  | JAN_REVIEW | A+B | 5f9f9ced JAN_REVIEW; 5cc73c6b PASS_B; f9bf7783 PASS_A | Jan: scope (non-profile page) |
| 222 | CU 869fhy0ca, IC 215476416630972 | privacy_access | 2026-10-15 22:22 | 2026-11-14 |  | ACCESS | - | 9a7b58fb | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 25 | legal@:1a141f84a3becd17, reg 25 | legal_threat | 2026-10-15 23:49 | 2026-11-14 |  | ALREADY_HIDDEN | - | d5a2d6b1 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 132 | CU 869fhyjkb, IC 215476418320223 | privacy_erasure | 2026-10-16 00:24 | 2026-11-15 |  | PASS_C | C | d17a10a9 PASS_C | hide batch |
| 257 | IC 215476422633398 | legal_threat | 2026-10-16 09:08 | 2026-11-15 |  | ASK_LINK | - | - | ASK: link line |
| 307 | IC 215476424461338 | privacy_erasure | 2026-10-16 12:26 | 2026-11-15 |  | ASK_LINK | - | - | ASK: link line |
| 131 | CU 869fjc8uv, IC 215476432321914 | privacy_erasure | 2026-10-16 20:07 | 2026-11-15 |  | PASS_A | A | f3edb450 PASS_A | hide batch |
| 117 | CU 1amvh554w9u, CU 869fjdjbv, IC 215476433384564, IC 215476568963954 | dmca_takedown | 2026-10-16 21:21 | 2026-11-15 |  | DMCA_REVIEW | - | 698b5507 DMCA_REVIEW; 98417319 DMCA_REVIEW | copyright review (claim-first) |
| 130 | CU 869fjcten, IC 215476433661576 | privacy_erasure | 2026-10-16 21:44 | 2026-11-15 |  | JAN_REVIEW | - | d4c7b7e3 GONE; 692e12d0 JAN_REVIEW | Jan: scope (non-profile page) |
| 265 | IC 215476435806951 | privacy_erasure | 2026-10-17 02:47 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 129 | CU 869fjf0d8, IC 215476438388307 | privacy_erasure | 2026-10-17 11:26 | 2026-11-16 |  | PASS_B | B | 43cf35c4 PASS_B | hide batch |
| 306 | IC 215476439779484 | privacy_erasure | 2026-10-17 15:30 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 291 | IC 215476440686324 | privacy_erasure | 2026-10-17 18:02 | 2026-11-16 |  | PASS_C | C | c99ad6be PASS_C | hide batch |
| 285 | IC 215476442306709 | privacy_erasure | 2026-10-17 20:11 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 305 | IC 215476442337306 | privacy_erasure | 2026-10-17 20:13 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 304 | IC 215476442355265 | privacy_erasure | 2026-10-17 20:15 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 303 | IC 215476442379883 | privacy_erasure | 2026-10-17 20:17 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 302 | IC 215476442393894 | privacy_erasure | 2026-10-17 20:20 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 282 | IC 215476442502607 | privacy_erasure | 2026-10-17 20:46 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 301 | IC 215476442545548 | privacy_erasure | 2026-10-17 20:57 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 300 | IC 215476442555280 | privacy_erasure | 2026-10-17 21:00 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 3 | CU 869fjhkzh, IC 215476442753765, reg 3 | privacy_erasure | 2026-10-17 21:48 | 2026-11-16 |  | PASS_C | C | ce6bf1bd PASS_C | hide batch |
| 289 | IC 215476442859313 | legal_threat | 2026-10-17 22:12 | 2026-11-16 |  | ASK_LINK | - | - | ASK: link line |
| 26 | notices@:1a15058a85f5f6e2, reg 26 | privacy_erasure | 2026-10-18 00:00 | 2026-11-17 |  | ALREADY_HIDDEN | - | 43940262 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 27 | notices@:1a15120bf1852d93, reg 27 | privacy_erasure | 2026-10-18 00:00 | 2026-11-17 |  | ALREADY_HIDDEN | - | 2dd39b03 ALREADY_HIDDEN; 3d57a164 ALREADY_HIDDEN; 882d042e ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 292 | IC 215476443877172 | privacy_erasure | 2026-10-18 00:12 | 2026-11-17 |  | ASK_LINK | - | - | ASK: link line |
| 4 | CU 869fjj1pc, CU 869fjj249, IC 215476444399022, reg 4 | privacy_erasure | 2026-10-18 02:46 | 2026-11-17 |  | ASK_IDENTITY | A | 26fbc3e5 ASK_IDENTITY; 6698820a ASK_IDENTITY; caff808e PASS_A | ASK: confirm-it's-you (v2 step 1) |
| 5 | CU 869fjj2bj, CU 869fjj2dp, IC 215476444480749, reg 5 | privacy_erasure | 2026-10-18 03:14 | 2026-11-17 |  | PASS_A | A | 026acd74 PASS_A | hide batch |
| 6 | CU 869fjjrpu, IC 215476446228963, reg 6 | privacy_erasure | 2026-10-18 08:57 | 2026-11-17 |  | PASS_C | C | 16106780 PASS_C | hide batch |
| 7 | CU 869fjkpd1, IC 215476447328122, reg 7 | legal_threat | 2026-10-18 12:38 | 2026-11-17 |  | GONE | - | 8cf938bc GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 128 | CU 869fjp4nj, IC 215476452883857 | cancel_intent_mentions_deletion | 2026-10-18 23:22 | 2026-11-17 |  | JAN_REVIEW | - | - | Jan: cancel-intent ticket that mentions deletion (read the customer's words) |
| 81 | notices@:1a151a7902b8abdc | privacy_erasure | 2026-10-19 00:54 | 2026-11-18 |  | UNKNOWN | - | c96b4f8e UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 221 | CU 869fjv5je, IC 215476457658039 | privacy_access | 2026-10-19 10:28 | 2026-11-18 |  | ACCESS | - | 3b6e115f | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 8 | CU 869fjwtgc, IC 215476458494245, reg 8 | legal_threat | 2026-10-19 12:03 | 2026-11-18 |  | ASK_LINK | - | - | ASK: link line |
| 277 | IC 215476459854106 | legal_threat | 2026-10-19 14:04 | 2026-11-18 |  | LEGAL_HIDE_FIRST | legal | 68817946 LEGAL_HIDE_FIRST | captain: legal threat, hide first (hide-batch --include-legal), identity after |
| 340 | IC 215476215218708 | legal_threat | 2026-10-19 14:18 | 2026-11-18 |  | ASK_LINK | - | - | ASK: link line |
| 298 | IC 215476460664382 | privacy_erasure | 2026-10-19 14:35 | 2026-11-18 |  | ASK_LINK | - | - | ASK: link line |
| 297 | IC 215476460914980 | privacy_erasure | 2026-10-19 14:54 | 2026-11-18 |  | ASK_LINK | - | - | ASK: link line |
| 296 | IC 215476460957251 | privacy_erasure | 2026-10-19 14:58 | 2026-11-18 |  | ASK_LINK | - | - | ASK: link line |
| 295 | IC 215476461615421 | privacy_erasure | 2026-10-19 15:40 | 2026-11-18 |  | ASK_LINK | - | - | ASK: link line |
| 217 | CU 1amvh554qcf, IC 215476464272174 | privacy_access | 2026-10-19 18:15 | 2026-11-18 |  | ACCESS | - | e06837db | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 276 | IC 215476464961922 | legal_threat | 2026-10-19 18:49 | 2026-11-18 |  | ASK_LINK | - | - | ASK: link line |
| 219 | CU 869fk3507, IC 215476465120521 | privacy_access | 2026-10-19 18:58 | 2026-11-18 |  | ACCESS | - | 809b8818 | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 10 | CU 869fk3t9e, reg 10 | privacy_erasure | 2026-10-19 23:16 | 2026-11-18 |  | ASK_LINK | - | - | ASK: link line |
| 11 | CU 869fk3taw, reg 11 | privacy_erasure | 2026-10-19 23:18 | 2026-11-18 |  | ASK_LINK | - | - | ASK: link line |
| 258 | IC 215476472196994 | legal_threat | 2026-10-20 08:45 | 2026-11-19 |  | ASK_LINK | - | - | ASK: link line |
| 294 | IC 215476480531034 | privacy_erasure | 2026-10-20 18:26 | 2026-11-19 |  | ASK_LINK | - | - | ASK: link line |
| 82 | notices@:1a15ad4cf03021cf | privacy_erasure | 2026-10-20 19:40 | 2026-11-19 |  | GONE | - | 7f00213c GONE; e3ac11fa GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 38 | reg 38 | dmca_takedown | 2026-10-20 20:54 | 2026-11-19 |  | DMCA_REVIEW | - | 7ea2bc87 ALREADY_HIDDEN; a9126433 DMCA_REVIEW; c0f0a65e ALREADY_HIDDEN; e42f2131 ALREADY_HIDDEN | copyright review (claim-first) |
| 293 | IC 215476485631108 | privacy_erasure | 2026-10-20 23:35 | 2026-11-19 |  | ASK_LINK | - | - | ASK: link line |
| 14 | CU 869fke0c8, IC 215476487093172, reg 14 | privacy_erasure | 2026-10-21 01:45 | 2026-11-20 |  | UNKNOWN | - | d1705031 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 53 | legal@:1a15c993a179826a, legal@:1a16724ec8f18019, notices@:1a15c9938ecf36e9, notices@:1a16724ec472b8bb | dmca_takedown | 2026-10-21 03:54 | 2026-11-20 |  | DMCA_REVIEW | - | 7ea2bc87 ALREADY_HIDDEN; a9126433 DMCA_REVIEW; c0f0a65e ALREADY_HIDDEN; e42f2131 ALREADY_HIDDEN | copyright review (claim-first) |
| 83 | notices@:1a15dda03c7cacbd, notice:7f27dc1c76403b97 | privacy_erasure | 2026-10-21 09:45 | 2026-11-20 |  | ASK_IDENTITY | - | e99ff4de ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 374 | CU 1amvh555nzr, IC 215476495232600 | cancel_intent_mentions_deletion | 2026-10-21 14:03 | 2026-11-20 |  | JAN_REVIEW | - | 42d7eefa | Jan: cancel-intent ticket that mentions deletion (read the customer's words) |
| 32 | IC 215476502219892, reg 32 | privacy_erasure | 2026-10-21 20:43 | 2026-11-20 |  | ASK_LINK | - | - | ASK: link line |
| 54 | legal@:1a16036801d9efc7 | privacy_erasure | 2026-10-21 20:45 | 2026-11-20 |  | ASK_LINK | - | - | ASK: link line |
| 31 | notices@:1a1611c4b666d5b3, reg 31 | privacy_erasure | 2026-10-22 00:00 | 2026-11-21 |  | ASK_IDENTITY | - | 08652f20 ASK_IDENTITY; 7344c2fe ALREADY_HIDDEN | ASK: confirm-it's-you (v2 step 1) |
| 33 | notices@:1a162f0b4d270c21, reg 33 | privacy_erasure | 2026-10-22 00:00 | 2026-11-21 |  | ALREADY_HIDDEN | - | e40d4dae ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 34 | CU 869fkvtbr, CU 869fm3mfb, notices@:1a162f8756028da7, support@:1a162f875c73f8c1, IC 215476510192929, reg 34 | legal_threat | 2026-10-22 00:00 | 2026-11-21 |  | GONE | - | 12519691 GONE; 7127c801 GONE; 8d96238f GONE; f6178264 GONE; fe69b1a2 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 36 | CU 869fm1q9p, CU 869fm1qda, support@:1a164aa9db4fc3b6, IC 215476518070915, reg 36 | privacy_erasure | 2026-10-22 00:00 | 2026-11-21 |  | ALREADY_HIDDEN | - | 0092c828 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 84 | notices@:1a161203f66e25d4 | privacy_erasure | 2026-10-22 01:00 | 2026-11-21 |  | ASK_IDENTITY | - | 08652f20 ASK_IDENTITY; 7344c2fe ALREADY_HIDDEN | ASK: confirm-it's-you (v2 step 1) |
| 35 | support@:1a16329fe67516fc, IC 215476510696760, reg 35 | dmca_takedown | 2026-10-22 10:31 | 2026-11-21 |  | JAN_REVIEW | - | 38a3e715 JAN_REVIEW | Jan: scope (non-profile page) |
| 290 | IC 215476517975325 | privacy_erasure | 2026-10-22 17:20 | 2026-11-21 |  | ASK_LINK | - | - | ASK: link line |
| 284 | IC 215476518241136 | privacy_erasure | 2026-10-22 17:49 | 2026-11-21 |  | ASK_LINK | - | - | ASK: link line |
| 37 | notices@:1a164bbd70a48edd, reg 37 | legal_threat | 2026-10-22 17:49 | 2026-11-21 |  | LEGAL_HIDE_FIRST | legal | 4946b8eb LEGAL_HIDE_FIRST | captain: legal threat, hide first (hide-batch --include-legal), identity after |
| 283 | IC 215476518299242 | privacy_erasure | 2026-10-22 17:56 | 2026-11-21 |  | ASK_LINK | - | - | ASK: link line |
| 127 | CU 869fm2bdg, IC 215476520604857 | privacy_erasure | 2026-10-22 21:04 | 2026-11-21 |  | ALREADY_HIDDEN | - | 61f4087f ALREADY_HIDDEN; 8e60c590 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 55 | legal@:1a16724626a9c50f, notices@:1a16724623c7bb00 | dmca_takedown | 2026-10-23 05:03 | 2026-11-22 |  | DMCA_REVIEW | - | 7ea2bc87 ALREADY_HIDDEN; a9126433 DMCA_REVIEW; c0f0a65e ALREADY_HIDDEN; e42f2131 ALREADY_HIDDEN | copyright review (claim-first) |
| 110 | CU 1amvh5554v0, IC 215476525549461 | privacy_erasure | 2026-10-23 10:04 | 2026-11-22 |  | ASK_IDENTITY | A+B | 6ab42bcb ASK_IDENTITY; aed8b9df PASS_B; d8349d2c ASK_IDENTITY; e776d9ac PASS_A | ASK: confirm-it's-you (v2 step 1) |
| 288 | IC 215476529167587 | privacy_erasure | 2026-10-23 15:27 | 2026-11-22 |  | ASK_LINK | - | - | ASK: link line |
| 286 | IC 215476529261783 | legal_threat | 2026-10-23 15:37 | 2026-11-22 |  | ASK_LINK | - | - | ASK: link line |
| 287 | IC 215476529645262 | legal_threat | 2026-10-23 16:05 | 2026-11-22 |  | ASK_LINK | - | - | ASK: link line |
| 126 | CU 1amvh555h3z, CU 869fm8z87, IC 215476530124913, IC 215476659568778, IC 215476678352187 | legal_threat | 2026-10-23 16:55 | 2026-11-22 |  | GONE | - | 43efa0ca GONE; 7871c617 GONE; c5d687e6 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 281 | IC 215476533805112 | legal_threat | 2026-10-23 20:43 | 2026-11-22 |  | ASK_LINK | - | - | ASK: link line |
| 280 | IC 215476534206047 | legal_threat | 2026-10-23 21:11 | 2026-11-22 |  | ASK_LINK | - | - | ASK: link line |
| 278 | IC 215476536179376 | privacy_erasure | 2026-10-24 02:02 | 2026-11-23 |  | ASK_LINK | - | - | ASK: link line |
| 279 | IC 215476540440008 | legal_threat | 2026-10-24 15:56 | 2026-11-23 |  | JAN_BIGNAME | legal | 09341358 LEGAL_HIDE_FIRST; 13f228a9 LEGAL_HIDE_FIRST; 408a2c1a JAN_BIGNAME; dfc083fe JAN_BIGNAME | Jan: big-name / high-credit page |
| 125 | CU 1amvh554prf, IC 215476541532340 | privacy_erasure | 2026-10-24 19:29 | 2026-11-23 |  | PASS_A | A | ab91628e PASS_A | hide batch |
| 124 | CU 1amvh554prj, CU 1amvh554prt, IC 215476541563542 | privacy_erasure | 2026-10-24 19:34 | 2026-11-23 |  | GONE | - | 61b02cb9 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 218 | CU 1amvh554pt4, IC 215476541874234 | privacy_access | 2026-10-24 20:50 | 2026-11-23 |  | ACCESS | - | 2dceeefb | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 260 | IC 215476329777526 | legal_threat | 2026-10-24 22:47 | 2026-11-23 |  | LEGAL_HIDE_FIRST | legal | 62c8477c LEGAL_HIDE_FIRST | captain: legal threat, hide first (hide-batch --include-legal), identity after |
| 253 | IC 215476542559417 | legal_threat | 2026-10-24 23:34 | 2026-11-23 |  | ASK_LINK | - | - | ASK: link line |
| 269 | IC 215476544388376 | legal_threat | 2026-10-25 06:54 | 2026-11-24 |  | JAN_BIGNAME | legal | 13f228a9 LEGAL_HIDE_FIRST; 408a2c1a JAN_BIGNAME; dfc083fe JAN_BIGNAME | Jan: big-name / high-credit page |
| 85 | notices@:1a1729eb04151e44 | privacy_erasure | 2026-10-25 10:32 | 2026-11-24 |  | ASK_LINK | - | - | ASK: link line |
| 107 | CU 1amvh554q2a, CU 1amvh554q2g, CU 1amvh555727, IC 215476545664506, IC 215476545719833, IC 215476611616733 | privacy_erasure | 2026-10-25 10:32 | 2026-11-24 |  | PASS_C | C | 285340fe PASS_C | hide batch |
| 123 | CU 1amvh554q8x, IC 215476548800791 | cancel_intent_mentions_deletion | 2026-10-25 16:21 | 2026-11-24 |  | JAN_REVIEW | - | - | Jan: cancel-intent ticket that mentions deletion (read the customer's words) |
| 216 | CU 1amvh554qda, IC 215476550405836 | privacy_access | 2026-10-25 19:56 | 2026-11-24 |  | ACCESS | - | 69ef584e | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 268 | IC 215476553442968 | privacy_erasure | 2026-10-26 04:04 | 2026-11-25 |  | ALREADY_HIDDEN | - | e303445e ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 122 | CU 1amvh554r40, IC 215476553978693 | dmca_takedown | 2026-10-26 06:10 | 2026-11-25 |  | ALREADY_HIDDEN | - | 1033fcae ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 121 | CU 1amvh554rgm, IC 215476554929415 | privacy_erasure | 2026-10-26 08:04 | 2026-11-25 |  | PASS_B | B | 15c0235b PASS_B | hide batch |
| 120 | CU 1amvh554u28, IC 215476556812865 | dmca_takedown | 2026-10-26 12:03 | 2026-11-25 |  | GONE | - | 0bbbde19 GONE; a4b530fb GONE; cb330e1c GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 275 | IC 215476562443906 | privacy_erasure | 2026-10-26 17:21 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 274 | IC 215476562444373 | privacy_erasure | 2026-10-26 17:21 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 273 | IC 215476562635129 | privacy_erasure | 2026-10-26 17:30 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 270 | IC 215476566208497 | legal_threat | 2026-10-26 20:57 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 114 | CU 1amvh554z8r, IC 215476567782449 | privacy_erasure | 2026-10-26 22:50 | 2026-11-25 |  | ASK_IDENTITY | A+B | 104b7c01 PASS_A; 723a3925 PASS_B; aed974aa ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 88 | support@:1a176619567e3fe0 | privacy_erasure | 2026-10-26 22:55 | 2026-11-25 |  | UNKNOWN | - | e303445e UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 89 | support@:1a176d4bb2c06b74 | privacy_erasure | 2026-10-26 22:55 | 2026-11-25 |  | ALREADY_HIDDEN | - | 1033fcae ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 90 | support@:1a17a6baec903b35 | privacy_erasure | 2026-10-26 22:55 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 91 | support@:1a17a6bb5c59a5fb | privacy_erasure | 2026-10-26 22:55 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 92 | support@:1a17a6bb8b5b12d6 | privacy_erasure | 2026-10-26 22:55 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 93 | support@:1a17a6c393316a98 | dmca_takedown | 2026-10-26 22:55 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 94 | support@:1a17a6c3f990e5af | dmca_takedown | 2026-10-26 22:55 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 95 | support@:1a17a6c968f948fe | privacy_erasure | 2026-10-26 22:55 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 96 | support@:1a17a6c9c764c427 | privacy_erasure | 2026-10-26 22:55 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 97 | support@:1a17a6ca5b6e2f06 | privacy_erasure | 2026-10-26 22:55 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 98 | support@:1a17a6ca8ebf30b5 | privacy_erasure | 2026-10-26 22:55 | 2026-11-25 |  | ASK_LINK | - | - | ASK: link line |
| 99 | support@:1a17a94f315a41fc | privacy_erasure | 2026-10-26 23:53 | 2026-11-25 |  | JAN_REVIEW | - | c18163e7 JAN_REVIEW | Jan: scope (non-profile page) |
| 118 | CU 1amvh554w9r, IC 215476568916411 | privacy_erasure | 2026-10-27 00:18 | 2026-11-26 |  | GONE | - | 603e75d6 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 252 | IC 215476571148960 | legal_threat | 2026-10-27 05:37 | 2026-11-26 |  | JAN_REVIEW | - | 3d00e2cf JAN_REVIEW; 153a79ef ALREADY_HIDDEN; 3a98fb32 ALREADY_HIDDEN | Jan: scope (non-profile page) |
| 116 | CU 1amvh554wrc, IC 215476571756456 | privacy_erasure | 2026-10-27 07:48 | 2026-11-26 |  | ASK_IDENTITY | - | 4de1963f ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 271 | IC 215476572017530 | privacy_erasure | 2026-10-27 08:26 | 2026-11-26 |  | PASS_B | B | 7aa5a7a3 PASS_B | hide batch |
| 115 | CU 1amvh554y84, IC 215476573902373 | privacy_erasure | 2026-10-27 11:45 | 2026-11-26 |  | JAN_REVIEW | A | f06dd6a4 JAN_REVIEW; b97bb454 PASS_A; 0f40011f JAN_REVIEW; 17799cef JAN_REVIEW; 1d68e46e JAN_REVIEW; 31e19152 JAN_REVIEW; 35b1fdf3 JAN_REVIEW; 35d7c8d7 JAN_REVIEW; 3f15eecc JAN_REVIEW; 45849995 JAN_REVIEW; 5db2d003 JAN_REVIEW; 984ccc79 JAN_REVIEW; b83fefcc JAN_REVIEW; ced0872e JAN_REVIEW; d3ea5690 JAN_REVIEW; e2b07c9e JAN_REVIEW; e7a5a51e JAN_REVIEW | Jan: scope (non-profile page) |
| 113 | CU 1amvh554ze3, IC 215476580437259 | dmca_takedown | 2026-10-27 18:09 | 2026-11-26 |  | GONE | - | 799687e8 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 112 | CU 1amvh554zev, IC 215476580656346 | privacy_erasure | 2026-10-27 18:21 | 2026-11-26 |  | PASS_A | A | 721b2259 PASS_A | hide batch |
| 267 | IC 215476582815238 | privacy_erasure | 2026-10-27 20:02 | 2026-11-26 |  | JAN_REVIEW | - | c18163e7 JAN_REVIEW | Jan: scope (non-profile page) |
| 266 | IC 215476511377491 | legal_threat | 2026-10-27 23:29 | 2026-11-26 |  | JAN_BIGNAME | - | c665f47e JAN_BIGNAME | Jan: big-name / high-credit page |
| 111 | CU 1amvh554zv2, IC 215476586690713 | privacy_erasure | 2026-10-28 02:08 | 2026-11-27 |  | ASK_IDENTITY | A | 21262a98 PASS_A; 715002d9 ASK_IDENTITY; e4d47d9a ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 86 | notices@:1a18350b2b650aa5, notice:53e41f30309c32a9 | privacy_erasure | 2026-10-28 16:20 | 2026-11-27 |  | UNKNOWN | - | 2e4d36aa UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 109 | CU 1amvh5554y9, IC 215476605752290 | cancel_intent_mentions_deletion | 2026-10-29 08:38 | 2026-11-28 |  | JAN_REVIEW | - | - | Jan: cancel-intent ticket that mentions deletion (read the customer's words) |
| 108 | CU 1amvh5556tg, IC 215476609937363 | privacy_erasure | 2026-10-29 14:37 | 2026-11-28 |  | ASK_LINK | - | - | ASK: link line |
| 100 | support@:1a18817d306d6243 | privacy_erasure | 2026-10-29 16:17 | 2026-11-28 |  | ASK_LINK | - | - | ASK: link line |
| 106 | CU 1amvh55574k, IC 215476612309838 | dmca_takedown | 2026-10-29 16:38 | 2026-11-28 |  | PASS_A | A | a6c98ec4 PASS_A | hide batch |
| 101 | support@:1a18886941ccfc53 | privacy_erasure | 2026-10-29 18:17 | 2026-11-28 |  | UNKNOWN | - | a6c98ec4 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 264 | IC 215476615536960 | privacy_erasure | 2026-10-29 19:08 | 2026-11-28 |  | UNKNOWN | - | 15ee60de UNKNOWN; 2e31dc17 UNKNOWN; 87e94d3d UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 105 | CU 1amvh5557f7, IC 215476615704033 | privacy_erasure | 2026-10-29 19:18 | 2026-11-28 |  | ASK_IDENTITY | B | 15ee60de ASK_IDENTITY; 2e31dc17 ASK_IDENTITY; 87e94d3d PASS_B | ASK: confirm-it's-you (v2 step 1) |
| 263 | IC 215476617290191 | privacy_erasure | 2026-10-29 20:48 | 2026-11-28 |  | ASK_LINK | - | - | ASK: link line |
| 104 | CU 1amvh5559a1, IC 215476619869024 | privacy_erasure | 2026-10-29 23:17 | 2026-11-28 |  | UNKNOWN | - | 340215d7 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 255 | IC 215476624683863 | legal_threat | 2026-10-30 04:23 | 2026-11-29 |  | ASK_LINK | - | - | ASK: link line |
| 262 | IC 215476626144845 | privacy_erasure | 2026-10-30 08:56 | 2026-11-29 |  | ASK_LINK | - | - | ASK: link line |
| 87 | notices@:1a18dc647fc31339, notice:50691b8e2bcd7636 | privacy_erasure | 2026-10-30 17:05 | 2026-11-29 |  | UNKNOWN | - | 0d7108a9 ASK_IDENTITY; c6ec95f2 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 102 | support@:1a18dced2b20f665 | privacy_erasure | 2026-10-30 18:17 | 2026-11-29 |  | ASK_LINK | - | - | ASK: link line |
| 375 | CU 1amvh555p5x, IC 215476634103353 | privacy_erasure | 2026-10-30 19:04 | 2026-11-29 |  | ASK_IDENTITY | - | 625b0ecd ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 254 | IC 215476639026911 | legal_threat | 2026-10-31 03:53 | 2026-11-30 |  | ASK_LINK | - | - | ASK: link line |
| 256 | IC 215476639065927 | legal_threat | 2026-10-31 04:04 | 2026-11-30 |  | ASK_LINK | - | - | ASK: link line |
| 261 | IC 215476642395644 | privacy_erasure | 2026-10-31 13:59 | 2026-11-30 |  | UNKNOWN | - | efe301fc UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 241 | IC 215476646666127 | privacy_erasure | 2026-11-01 02:05 | 2026-12-01 |  | ASK_LINK | - | - | ASK: link line |
| 103 | CU 1amvh555e7c, notices@:1a194efa56b984ca, IC 215476646836686, notice:1ca6d46242e5d523 | privacy_erasure | 2026-11-01 02:28 | 2026-12-01 |  | ASK_IDENTITY | - | 374c1e32 ASK_IDENTITY | ASK: confirm-it's-you (v2 step 1) |
| 39 | CU 1amvh555f30, notices@:1a197914836dcec8, IC 215476650395415, notice:f29c736982c072ca, reg 39 | privacy_erasure | 2026-11-01 14:43 | 2026-12-01 |  | ALREADY_HIDDEN | - | 7950a3c4 ALREADY_HIDDEN | verify S/P/M, confirm by due date |
| 259 | IC 215476653443738 | legal_threat | 2026-11-01 20:20 | 2026-12-01 |  | ASK_LINK | - | - | ASK: link line |
| 240 | CU 1amvh555fhe, IC 215476654753723 | privacy_erasure | 2026-11-01 22:51 | 2026-12-01 |  | PASS_A | A | 6c1e4b9f PASS_A | hide batch |
| 239 | CU 1amvh555gkg, CU 1amvh555gn7, IC 215476659061571, IC 215476659165597 | cancel_intent_mentions_deletion | 2026-11-02 09:37 | 2026-12-02 |  | JAN_REVIEW | - | 0f6a8277 | Jan: cancel-intent ticket that mentions deletion (read the customer's words) |
| 245 | notices@:1a19bad4cd8c3790, notice:e88461ed57b4e1df | privacy_erasure | 2026-11-02 09:52 | 2026-12-02 |  | ASK_LINK | - | - | ASK: link line |
| 246 | notices@:1a19bd3db91a82d9, notice:4c261cf78cbd7d47 | privacy_erasure | 2026-11-02 10:34 | 2026-12-02 |  | UNKNOWN | - | 43efa0ca UNKNOWN; 7871c617 GONE; c5d687e6 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 238 | CU 1amvh555kg5, IC 215476669606238 | privacy_erasure | 2026-11-02 20:30 | 2026-12-02 |  | ASK_LINK | - | - | ASK: link line |
| 247 | CU 1amvh555m09, IC 215476672531243 | cancel_intent_mentions_deletion | 2026-11-02 23:34 | 2026-12-02 |  | JAN_REVIEW | - | - | Jan: cancel-intent ticket that mentions deletion (read the customer's words) |
| 249 | notices@:1a1a0d93269bfc06, notice:ce2345ae298e43ed | privacy_erasure | 2026-11-03 09:59 | 2026-12-03 |  | ASK_LINK | - | - | ASK: link line |
| 250 | CU 1amvh555mzj, IC 215476678502061 | privacy_erasure | 2026-11-03 09:59 | 2026-12-03 |  | ASK_LINK | - | - | ASK: link line |
| 373 | legal@:1a1a12450e7d1fab, notice:bf4393b5d2af9ce2 | privacy_erasure | 2026-11-03 11:21 | 2026-12-03 |  | ASK_LINK | - | - | ASK: link line |
| 251 | IC 215476679173052 | privacy_erasure | 2026-11-03 11:21 | 2026-12-03 |  | ASK_LINK | - | - | ASK: link line |
| 380 | IC 215476687141837 | privacy_erasure | 2026-11-03 20:01 | 2026-12-03 |  | ASK_LINK | - | - | ASK: link line |
| 378 | CU 1amvh555q6j, CU 1amvh555q6v, IC 215476688257393 | privacy_erasure | 2026-11-03 20:55 | 2026-12-03 |  | ASK_LINK | - | - | ASK: link line |
| 379 | CU 1amvh555qde, IC 215476692569995 | privacy_access | 2026-11-04 01:11 | 2026-12-04 |  | ACCESS | - | 57e35102 | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 377 | CU 1amvh555qdn, notices@:1a1a436083a51047, IC 215476692845876, notice:bf70f05c2b576859 | privacy_erasure | 2026-11-04 01:39 | 2026-12-04 |  | GONE | - | fc31a861 GONE | Jan: page already 404 (deleted/merged outside the hide process) - confirm what was done, then the letter |
| 381 | CU 1amvh555qkx, IC 215476694910299 | privacy_erasure | 2026-11-04 07:31 | 2026-12-04 |  | ASK_IDENTITY | A+B | 2e6f83a1 PASS_B; 8d9e13a0 ASK_IDENTITY; f97c601a PASS_A | ASK: confirm-it's-you (v2 step 1) |
| 382 | CU 1amvh555txr, IC 215476466968451 | privacy_erasure | 2026-11-04 14:47 | 2026-12-04 |  | PASS_A | A | cc8fd107 PASS_A | hide batch |
| 383 | IC 215476704158624 | privacy_erasure | 2026-11-04 18:08 | 2026-12-04 |  | ASK_LINK | - | - | ASK: link line |
| 384 | CU 1amvh555v34, IC 215476708867447 | legal_threat | 2026-11-04 22:13 | 2026-12-04 |  | LEGAL_HIDE_FIRST | legal | c3cb6cac LEGAL_HIDE_FIRST | captain: legal threat, hide first (hide-batch --include-legal), identity after |
| 387 | IC 215476710443108 | privacy_erasure | 2026-11-05 00:02 | 2026-12-05 |  | PASS_B | B | 6b692163 PASS_B | hide batch |
| 385 | support@:1a1a8d82a4d83b15 | privacy_erasure | 2026-11-05 00:17 | 2026-12-05 |  | UNKNOWN | - | 6b692163 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 386 | support@:1a1a90381300bbf2 | privacy_erasure | 2026-11-05 00:17 | 2026-12-05 |  | UNKNOWN | - | 6b692163 UNKNOWN | read the mail thread: the full page link and the sender are not on file (the Gmail readers are disabled since 31 Oct), then the next run decides |
| 388 | support@:1a1a96ed297132b5 | dmca_takedown | 2026-11-05 02:17 | 2026-12-05 |  | DMCA_REVIEW | - | 6b692163 DMCA_REVIEW | copyright review (claim-first) |
| 389 | IC 215476552606996 | privacy_erasure | 2026-11-05 10:52 | 2026-12-05 |  | ASK_LINK | - | - | ASK: link line |
| 390 | IC 215476680827878 | legal_threat | 2026-11-05 18:52 | 2026-12-05 |  | ASK_LINK | - | - | ASK: link line |
| 392 | CU 1amvh555ykm, IC 215476725259597 | privacy_access | 2026-11-05 19:29 | 2026-12-05 |  | ACCESS | - | - | Art. 15 access request: captain/counsel answer (no hide); due date tracked |
| 391 | CU 1amvh555ym1, IC 215476725681142 | privacy_access | 2026-11-05 19:56 | 2026-12-05 |  | ACCESS | - | b7986765 | Art. 15 access request: captain/counsel answer (no hide); due date tracked |

## The ask batch, measured on the live store (2026-11-06T02:2xZ)

`gdpr-pipeline.py ask` renders **145 letters**, batch digest **`38b0d4a96a360dd5`**. Route census, measured with the
deployed environment on node-8 (so `gog`'s account list is real, not a local guess) by calling `send.route()` on every
item:

| route | letters | note |
|---|---|---|
| `intercom` | 110 | reply in the conversation |
| `mail` | 11 | reply in the support@ thread |
| `mail_new_thread` | 9 | a notices@/legal@ request whose thread lives in a mailbox this host cannot write: open a new thread from support@ (hydra #1749) |
| **refused** | **15** | no route the pipeline can take; each is ledgered `refused` with its reason, never a silent skip |

The 2026-11-05 cut of this table read 144 letters / digest `b91c208e8750edc6` / 24 refused. The refused count fell to
15 because the new-thread route (#1749) now reaches 9 of them; the rest are rows with neither a conversation nor a
thread to reply to (a bare `requester_email`), which stay refused until somebody supplies the page link.

**Nothing has ever been sent** (`erasure_sends` is empty), so every one of the 174 past-due rows is a statutory
deadline already missed, not a letter in flight. The send path is unlocked in code (`copy.PIPELINE_SENDS_APPROVED`)
and gated twice: an allowlisted human's Slack approval naming this digest, or the standing ruling
`standing-erase-ask-1104` which arms at **2026-11-05T21:30Z** (Fable decision 11-04 B26 Q1, under the captain's
delegation, with a 24 h veto).

## The hide batch

`gdpr-pipeline.py hide-batch` plans **13 new ids** for the routine batch, with **42 more already in flight** in the
open H-DevOps #4624 (the H-DevOps half of the 2026-11-01 batch; the PDP half, #2575, merged 2026-11-03T20:44Z). The
new 13 are deferred behind that merge: both PRs of a batch insert at the same point in the same list file, so a
second pair would only conflict. Pages held by an open `legal_threat` row's hide-first verdict are excluded unless
`--include-legal`, because that is the captain's call, not the pipeline's.

Since 2026-11-06 the batch is also **scheduled** (`gdpr-hide-batch.timer`, daily) rather than run by hand, so a row
whose identity PASSed stops waiting on somebody remembering.

Reversible hide only: 410 + noindex. Nothing is ever deleted (`DELETE /api/v3/admin/profile` and `muso-cli delete` are
never called; legal hold 1350).
