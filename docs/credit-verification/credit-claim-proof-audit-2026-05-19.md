# Phase 0 audit — Caroline `credit-claim-with-proof` Lobster pipeline

Status: **findings filled in 2026-05-21 — recommendation: GO**, pending
a short check-in with Jan on tier choice + cap signoff.

Date opened: 2026-05-19
Audit run: 2026-05-21 on hydra node-8. Raw output (transient, in /tmp):
`/tmp/cv-proof-audit-2026-05-21/out/intercom-audit-20260521/` — re-run
the script per the "How to run" section below to reproduce.
Owner: Nick + Claude

## Why this audit exists

Jan asked (Slack, 2026-05-19):

> "if the user will provide a proof for their credit claim (verification
> needed). Caroline will create a ticket?"

Today Caroline can't see attachments at all — the Intercom plugin
extracts only message body text (`plugins/intercom/src/filters.ts:16-17`,
`types.ts:68-75`). A user sending "here's my proof" + PDF becomes
"here's my proof" in Caroline's context; the file is invisible. The
credit-claim ticket Caroline creates doesn't reference the proof; Jan
has to dig through Intercom manually.

The proposed fix is a Lobster pipeline (`workspaces/support/skills/credit-claim-with-proof/`)
that detects proof attachments, downloads them from Intercom, uploads
them to ClickUp, and creates a ticket auto-assigned to Jan. Real
engineering: Intercom plugin changes, new pipeline, new action_type
with a server gate, ClickUp file-upload helper, plus all the testing
machinery (mode gates, idempotency, kill switch).

Before any of that ships, we need to answer questions we currently
can't from inside the repo:

| Question | Why it gates the design |
|---|---|
| How often do users actually attach proof? | Sets ROI. If <2/week, the project may not be worth the engineering. |
| What file types do they send? (PDF? screenshots? zips?) | Sets the content-type allowlist in the pipeline. |
| What sizes? (small contracts? big audio stems?) | Sets per-file and total-payload caps. |
| What phrasing do customers use? ("here's my proof"? "see attached"? framing varies) | Informs Caroline's classifier — the difference between "proof + claim intent" and "random attachment". |
| Does Caroline currently respond usefully or silently ignore? | Baseline for measuring success post-deploy. |

## Methodology

`scripts/intercom/audit-credit-claim-attachments.sh` queries the
Intercom REST API for conversations in the last 90 days matching
credit-claim keywords, walks each conversation's parts, and emits:

- `out/intercom-audit-YYYYMMDD/conversations.csv` — per-conversation
  attachment counts, content types, sizes, and a body snippet.
- `out/intercom-audit-YYYYMMDD/summary.json` — aggregate stats:
  candidate count, attachment rate, content-type frequency, size
  buckets.
- `out/intercom-audit-YYYYMMDD/conversations/<id>.json` — raw API
  responses for offline re-analysis (sampling, deeper classification).

See `scripts/intercom/README.md` for run instructions.

### Search keywords used

The script ORs across these body-substring matches (Intercom v2.11
search supports the `~` operator):

```
produced this, produced the track, co-writer, co-write, co-wrote,
writer credit, producer credit, credit on, add my credit, proof,
see attached, here is, split sheet, release form, contract
```

Broad on purpose. Dedup by conversation ID; classification happens
client-side from the raw response archive.

### What we'll filter for, post-audit

From the raw archive, sample by hand:

- **True positives:** conversation has clear credit-claim intent AND a
  user-attached file that's recognizable as proof (contract,
  split-sheet PDF, screenshot of streaming dashboard, etc.).
- **False positives:** customer sent a file but it's not credit-claim
  context (e.g. dispute evidence, billing screenshot, profile-photo).
- **Misses:** credit-claim intent but no attachment — these stay in
  the existing `credit-claim` flow, not this pipeline.

The true-positive rate determines whether the keyword classifier is
viable, or whether we need a richer signal (e.g. attachment-presence
alone, regardless of text).

## How to run

```bash
export INTERCOM_TOKEN="$(jq -r '.channels.intercom.accounts.default.token' openclaw-edge.json)"
scripts/intercom/audit-credit-claim-attachments.sh
cat out/intercom-audit-$(date -u +%Y%m%d)/summary.json
```

Run on node-8 where the token already exists, or anywhere with the
token + jq + curl + network access to `api.intercom.io`.

Roughly 5–15 minutes for 90 days of data with default rate limiting.

## Findings (audit run 2026-05-21)

### Top-line numbers

| Metric | Value |
|---|---|
| Window | 90 days (updated_at since 2026-02-20) |
| Candidate conversations matching keyword OR-set | 500 — **hit the `MAX_CONVS=500` cap, so this is a floor, not a count** |
| Convs with ≥1 user-side attachment | **248 (49.6%)** |
| Total user-side attachments across those convs | 318 (≈1.28/conv) |
| Eyeball precision (30 random samples, hand-classified) | **~27/30 = ~90% true credit-claim-with-proof** |

### Volume → decision

- 248 attachment-bearing convs / 90 days ≈ **2.76/day ≈ 19.3/week** (raw)
- After ~90% precision adjustment: **~17.4/week** real credit-claim-with-proof events
- Both far above the **>5/week → GO** threshold.
- Caveat: the 500-conv cap was reached, so true keyword-matching volume is
  ≥500 in 90d; the attachment rate of ~50% likely holds on the un-sampled
  tail, putting the real volume even higher.

- [x] **>5/week:** clear go. Proceed to PR B (Intercom plumbing).
- [ ] **2–5/week:** marginal.
- [ ] **<2/week:** stop here.

### File mix (from `summary.json:content_type_frequency`, n=318 attachments)

| content_type | count | share |
|---|---:|---:|
| image/png | 138 | 43.4% |
| image/jpeg | 106 | 33.3% |
| application/pdf | 28 | 8.8% |
| application/force-download | 22 | 6.9% |
| audio/mpeg | 14 | 4.4% |
| video/mp4 | 6 | 1.9% |
| audio/mp4 | 3 | 0.9% |
| application/vnd.openxmlformats-officedocument.spreadsheetml.sheet | 1 | 0.3% |

- **Dominant types:** images dominate (76.7%, mostly screenshots of streaming
  dashboards, Discogs, AllMusic, social media posts). PDFs (8.8%) are
  contracts and split-sheets. Audio (5.3%) is project files / stems sent
  as proof of authorship.
- **`application/force-download` (6.9%)** is Intercom's fallback when the
  uploader didn't supply a content-type — almost always audio in the
  raw archives. Treat as bytes, infer from filename extension.
- **No `.exe`, `.heic`, or other surprises in the tail.** The xlsx is a
  one-off (release form spreadsheet).
- **Recommendation for Phase 2 allowlist:** `image/*`, `application/pdf`,
  `audio/*`, `video/*`, `application/force-download` (treat as binary
  with filename inspection), plus `application/vnd.openxmlformats-*`
  for office docs. Reject anything else explicitly with a Caroline
  message so customers know to re-send.

### Size budget (n=248 attachment-bearing convs)

Per-conversation total (sum of all attachments in that conv):

| Percentile | Bytes | Human |
|---|---:|---:|
| p50 | 1,880,398 | 1.8 MB |
| p75 | 5,621,990 | 5.4 MB |
| p90 | 11,959,063 | 11.4 MB |
| p95 | 17,626,323 | 16.8 MB |
| p99 | 28,159,225 | 26.9 MB |
| max | 145,595,513 | 138.8 MB (single outlier — likely a raw multitrack ZIP) |

Largest single attachment in any conv:

| Percentile | Bytes | Human |
|---|---:|---:|
| p50 | 639,730 | 625 KB |
| p95 | 8,447,168 | 8.1 MB |
| p99 | 17,019,626 | 16.2 MB |
| max | 37,677,210 | 35.9 MB |

Bucket distribution: 87 convs `<1MB`, 95 `1-5MB`, 63 `5-25MB`, 2 `25-100MB`, 1 `>100MB`.

- **Per-file cap recommendation: 50 MB.** p99 single-attachment is 16 MB,
  max is 36 MB — 50 MB gives healthy headroom and covers 100% of observed
  individual files.
- **Total-payload cap recommendation: 100 MB.** Covers 99.6% of observed
  convs (loses only the 138 MB outlier). For that one outlier, Caroline
  should fall back to "I'll let Jan know" without the auto-upload and let
  Jan handle it manually.

### Customer framing (eyeballed from 30 random attachment-bearing snippets)

Top patterns, ordered by frequency in the sample:

1. **Reactive: customer replies to a "could you please share documentation
   for the pending track/s?" prompt from John/Dave, with attachments and
   minimal accompanying text.** The original prompt is usually quoted in
   the body. This was the most common pattern — roughly half the sample.
2. **"Here's [my proof / the project file / screenshots / a screenshot
   of …]"** — explicit proof framing, customer-initiated.
3. **Role + work statement: "I produced / mixed / mastered / co-wrote
   [track]"** + attachments — credential + proof in one turn.
4. **Document-type cue: "I'm sending [project file / contract / lease
   agreement / split sheet / release form]"** — explicit doc type called
   out by name.
5. **Third-party verification: "You can find my name in [Discogs / AllMusic
   / YouTube description / Spotify]"** + screenshot of that page.

**Classifier implication:** the body text is often near-empty (the
attachment IS the message). A text-only classifier will miss most of
these. The reliable signal is **"user-side message + ≥1 attachment in
a credit-claim conversation"**, where the credit-claim context is
established by either (a) a recent admin prompt asking for documentation,
or (b) the conv already being routed under credit-claim intent.

The keyword regex from the audit (`produced this | proof | see attached |
split sheet | contract | …`) had ~90% precision in the 30-sample eyeball
— good enough as a pre-filter, not as a sole classifier.

### Caroline's current behavior

Caroline only began handling Intercom traffic broadly on 2026-05-18 (the
Lobster pilot cutover — see `project_credit_verification_lobster_pilot`).
Of the 248 attachment-bearing convs in the window, 159 were updated after
2026-05-12, but the conv-creation skew means very few were exclusively
"Caroline answered an attachment turn" — most are older convs where John
or Dave was the admin.

**Practical baseline:** Caroline today extracts only `lastPart?.body`
(`plugins/intercom/src/filters.ts:16-17`), so any attachment-bearing
user turn arrives at her as text-only. She can either (a) thank the
customer and create a generic `credit-claim` ticket without referencing
the file (its presence is invisible to her), or (b) ask for clarification
because the text alone is ambiguous. Either way the file ends up in
Intercom only; Jan has to dig for it.

A formal pre-deploy baseline isn't useful here (Caroline is too new and
the surface is changing weekly). The post-deploy measurement we care
about is: of the next N proof-attached convs after this pipeline ships,
how many get a Jan-assigned ClickUp ticket with the file uploaded
correctly, without human intervention?

### Jan's input — TODO before PR B starts

The numerical findings above don't need Jan to make sense, but the
tier choice and per-file cap do. Pending a short Slack check-in:

- Top file types Jan sees in her current manual workflow: **TODO (Nick to confirm with Jan)**
- Top phrasings she keys on: **TODO**
- Current workaround when she gets a generic `credit-claim` ticket
  with proof hidden in Intercom: **TODO**
- What tier proof-attached cases should get (1 = 2 bd, 2 = 5 bd): **TODO — default Tier 2 unless Jan flags urgency**

Not a blocker for merging this Phase 0 PR — Jan's input shapes PR B
(plumbing) and PR C (pipeline), not the GO/DEFER decision itself.

### Recommendation

- [x] **GO.** Proceed to PR B (Intercom plumbing). Specific decisions:
  - **tier:** 2 (5 bd) — default; Jan can override to Tier 1 if she
    flags urgency in her check-in.
  - **per-file cap:** 50 MB (covers 100% of observed individual files,
    p99 is 16 MB).
  - **total-payload cap:** 100 MB per conversation (covers 99.6% of
    observed convs; the one >100 MB outlier falls back to "I'll flag
    Jan manually").
  - **content-type allowlist:** `image/*`, `application/pdf`, `audio/*`,
    `video/*`, `application/force-download` (treat as binary, inspect
    filename extension), `application/vnd.openxmlformats-*`. Reject
    anything else with a polite Caroline message.
- [ ] **DEFER.**
- [ ] **REDESIGN.**

**One genuine surprise from the audit:** customer text is often
near-empty on the proof turn — the attachment IS the message.
Implication for PR C: don't gate on text-classifier confidence
alone. Use **"user-side message with ≥1 attachment in a
credit-claim-context conversation"** as the primary trigger.
"Credit-claim context" = prior admin turn asked for documentation,
OR conv is already routed under credit-claim intent in Caroline's
existing classifier.

### Out of caveats

- **MAX_CONVS=500 cap was reached.** True candidate volume in the
  90-day window is ≥500, not exactly 500. All ratios (attachment
  rate, content-type mix, sizes) hold as a representative sample,
  but the absolute weekly rate is a floor. Doesn't change the GO
  decision (the floor is already >3x the threshold).
- **The Intercom search field `source.body` matches only the conv's
  initial inbound message body** — conversation_parts and admin/user
  replies are NOT searched ([Intercom v2.11 search docs](https://developers.intercom.com/docs/references/rest-api/api.intercom.io/conversations/searchconversations)).
  Most of the attachment-bearing turns we care about are REPLIES
  (customer responding to a "share documentation" admin prompt), which
  only entered this audit's sample if the original conv opener also
  happened to contain one of the keywords. So two biases compound:
  (a) the 248/90d figure is a structural undercount (the floor is even
  lower than MAX_CONVS suggests), and (b) the customer-framing
  distribution skews toward convs whose source already matched the
  keywords. PR B's classifier should NOT lean on this keyword set as
  exhaustive — gate on attachment-presence + credit-claim-context
  established by Caroline's existing intent classifier or a recent
  admin "share documentation" prompt, not on text matching the audit
  regex. Both biases reinforce the GO call rather than weaken it.
- **Precision (~90%) is eyeballed from 30 random samples**, not
  exhaustive. The 10% false-positive tail is mostly profile-merge
  requests and stats-not-updating tickets — neither dangerous to
  classify-as-proof, just adds noise; PR B/C should still gate on
  attachment presence.

## Out of scope for Phase 0

- OCR / vision content extraction from the attachments. Phase 1+ deals
  with relay (Intercom → ClickUp), not interpretation.
- Sampling actual file content for sensitivity (PII, contract text).
  The audit operates on metadata only.
- Surveying ops/support team members other than Jan. Scope this Phase
  0 to Jan's expertise; broader survey is a separate exercise.

## Cross-references

- Approved plan: `/Users/nick/.claude/plans/so-opsagent-credit-verification-enumerated-cherny.md`
- PR #298 (profile-merge gate — sibling work, already shipped/merging):
  https://github.com/Muso-AI/hydra/pull/298
- Deferred refund-processor design (Lobster pattern reference):
  `docs/refund-processor-lobster-design.md`
- Lobster cutover audit (why we picked these targets):
  `docs/lobster-cutover-audit.md`
