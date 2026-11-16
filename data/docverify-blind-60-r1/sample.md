# docverify-blind-60-r1: the blind sample of 60

Drawn read-only on node-8, 2026-11-16, by `tools/draw_sample.py` (seed `docverify-blind-60-r1`, verifier `dv-4`).

## The population: the 980

Every document with a standing `dv-4` outcome written at or before `2026-11-15T01:23:59Z` whose extraction (as of that time) is ok and has a document type the gate accepts as a record (`gate.RECORD_DOC_TYPES`). That is the measurement the "980 real record-type documents" came from (docverify-blind-check-r1, `support_by_type.json`, 2026-11-15 01:23Z); frozen at that time it reproduces **980** exactly (with 8,167 not-record and 796 without an extraction, the same as then). The live count has since grown to 1,072; the draw does not use it.

The draw reads only each document's id and its extraction's type. It reads no outcome, reason, gate detail or extracted support, so nothing the reader decided can steer which documents are in the sample.

## Stratification: population and draw per type

Proportional allocation of 60 over the 980 (largest remainder), then a seeded uniform draw inside each type.

| stratum (extraction `doc_type`) | brief's name | population | share x 60 | drawn |
|---|---|---|---|---|
| `split_sheet` | split sheet | 75 | 4.59 | 5 |
| `contract` | (not in the brief) | 194 | 11.88 | 12 |
| `invoice` | (not in the brief) | 348 | 21.31 | 21 |
| `letter` | label letter | 30 | 1.84 | 2 |
| `pro_registration` | PRO registration | 282 | 17.27 | 17 |
| `receipt` | (not in the brief) | 51 | 3.12 | 3 |
| **total** | | **980** | 60.00 | **60** |

**Two of the brief's five types have no population, and three record types the brief did not name do.**

- `pro_portal` is not a document type the extraction gives. It is an H3 *kind* (`gate.RECORD_H3_KINDS`), a second route through the same record check, and the 980 is defined by the extraction's type. Population 0, drawn 0.
- *royalty statement* is not a type the extraction has (its types are the six above plus the non-record ones). Population 0, drawn 0.
- Their share is not lost: the allocation is over the types that exist, so the 60 comes entirely from the 980. `invoice`, `contract` and `receipt` (593 of the 980, 61%) are record types the brief did not list; leaving them out would have drawn from 387 documents, not the 980.
- `letter` has 30 documents, so its proportional share is 1.84; it gets 2 by largest remainder. No type has fewer documents than its share.

## The 60

`id` is the first 16 hex characters of the proof id (the sha256 of the document bytes). The full ids stay off git, in the task's data directory; the tool, the seed and the cutoff re-draw the same 60.

| # | id | document type | stratum |
|---|---|---|---|
| 1 | `c4445bca9d44a68c` | `contract` | `contract` |
| 2 | `c6d18cbd36c51502` | `contract` | `contract` |
| 3 | `03fc765a8a0c4c32` | `contract` | `contract` |
| 4 | `04f93ae2d6d9897c` | `contract` | `contract` |
| 5 | `d10d4a2d3c66a202` | `contract` | `contract` |
| 6 | `23d226788eed777f` | `contract` | `contract` |
| 7 | `f6b59558ba5d5856` | `contract` | `contract` |
| 8 | `ef731f15f543600b` | `contract` | `contract` |
| 9 | `f7ab0c180cbb6c30` | `contract` | `contract` |
| 10 | `3631989c189feac9` | `contract` | `contract` |
| 11 | `55dfd5f1b68d2c3d` | `contract` | `contract` |
| 12 | `620148a7d8a37641` | `contract` | `contract` |
| 13 | `17a7b5fefa616c9f` | `invoice` | `invoice` |
| 14 | `037510c3c692c4e3` | `invoice` | `invoice` |
| 15 | `a24acf94501b5cdf` | `invoice` | `invoice` |
| 16 | `cf138138de09ba1f` | `invoice` | `invoice` |
| 17 | `c061b0d649fd22ea` | `invoice` | `invoice` |
| 18 | `0f848eecb24deba5` | `invoice` | `invoice` |
| 19 | `4e98631d47de91b5` | `invoice` | `invoice` |
| 20 | `f423dd9d40f2d545` | `invoice` | `invoice` |
| 21 | `000d94ad60354d5d` | `invoice` | `invoice` |
| 22 | `e5e65fe048687e89` | `invoice` | `invoice` |
| 23 | `b6d5662421144145` | `invoice` | `invoice` |
| 24 | `f523c1247e744461` | `invoice` | `invoice` |
| 25 | `13359c0adc19caae` | `invoice` | `invoice` |
| 26 | `070d6bb2c4808ab9` | `invoice` | `invoice` |
| 27 | `c425e59711383d4d` | `invoice` | `invoice` |
| 28 | `ba39f9af35db7be1` | `invoice` | `invoice` |
| 29 | `a7a1d7e27dcfbaa9` | `invoice` | `invoice` |
| 30 | `c285f5a6621d4d7f` | `invoice` | `invoice` |
| 31 | `7c252f94d377123a` | `invoice` | `invoice` |
| 32 | `136736d5df4f026a` | `invoice` | `invoice` |
| 33 | `b9d96c4669704ddc` | `invoice` | `invoice` |
| 34 | `56a76e5a3d438e9f` | `letter` | `letter` |
| 35 | `347280413693aeb2` | `letter` | `letter` |
| 36 | `54ffc423c6fde61d` | `pro_registration` | `pro_registration` |
| 37 | `ff52e4d7478b93a9` | `pro_registration` | `pro_registration` |
| 38 | `e6ed5b9d65b75a73` | `pro_registration` | `pro_registration` |
| 39 | `346bb6b3071d98c4` | `pro_registration` | `pro_registration` |
| 40 | `cb5f24cc85d11678` | `pro_registration` | `pro_registration` |
| 41 | `813b581ef90a25cd` | `pro_registration` | `pro_registration` |
| 42 | `0a133385a0d5b75f` | `pro_registration` | `pro_registration` |
| 43 | `d134cda6d2a945c5` | `pro_registration` | `pro_registration` |
| 44 | `a5a35b7a5691e1d3` | `pro_registration` | `pro_registration` |
| 45 | `f9e4820d11f72565` | `pro_registration` | `pro_registration` |
| 46 | `8a4baec2d583b305` | `pro_registration` | `pro_registration` |
| 47 | `059e593efdc1c5bf` | `pro_registration` | `pro_registration` |
| 48 | `4163bbf389f8abd0` | `pro_registration` | `pro_registration` |
| 49 | `6224b5374b120564` | `pro_registration` | `pro_registration` |
| 50 | `7b499dc25eb7599f` | `pro_registration` | `pro_registration` |
| 51 | `0e291a316b471dab` | `pro_registration` | `pro_registration` |
| 52 | `5e75369fbf325878` | `pro_registration` | `pro_registration` |
| 53 | `87eb5de1606f440a` | `receipt` | `receipt` |
| 54 | `da6254ee54ba45e4` | `receipt` | `receipt` |
| 55 | `737802aff2a0043b` | `receipt` | `receipt` |
| 56 | `787c1dd165361ea1` | `split_sheet` | `split_sheet` |
| 57 | `1698eefc18d0e4f3` | `split_sheet` | `split_sheet` |
| 58 | `b2361a3b79a7d7e7` | `split_sheet` | `split_sheet` |
| 59 | `25961da52757bd6d` | `split_sheet` | `split_sheet` |
| 60 | `3364ff9cf3732805` | `split_sheet` | `split_sheet` |

The sample is fixed. It is not re-drawn after the reader is scored, whatever the score.
