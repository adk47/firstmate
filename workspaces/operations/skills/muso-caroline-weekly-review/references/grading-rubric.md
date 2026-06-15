# Caroline Daily Review: Grading Rubric

Every dimension scores 0-5. P0/P1/P2 severity per finding. P0 in any dimension forces the Slack headline.

Daily pulse: dimensions A (voice + leak), B (tools), D (sentiment), E (reasoning-leak / guard health), plus an informational Themes pass (>=2 unique customers). Weekly roll-up: the same dimensions over a 168h window, plus KB-gap candidates (the old Dimension C, >=3 unique customers, Slack-surface only — auto-PR stays manual in v1). Neither mode opens PRs.

## Severity ladder

- **P0**: any `[intercom:tool-leak]` audit line in window, OR an `[intercom:email-leak]` line whose `leak_class` is `internal` (a non-support `@muso.ai` employee address Caroline tried to hand out) or `unknown` (an email-leak line whose address could not be parsed — fail closed), OR any regression pattern from Dimension B (analytics→email/support loop), OR a SHIPPED reasoning leak the guard missed (Dimension E, source 2: a reply that reached a customer).
- **P1**: wrong escalation, wrong actionType/tier, missed required `profile_status` call on an analytics/streams conversation, refund 3-gate skipped, OR an ESCALATED reasoning-leak conv with no human reply yet (Dimension E: a customer is waiting on a human).
- **P2**: voice blacklist hit ("Great question", em-dash, "investigate", apologies-for-analytics), sentiment issue, OR an `[intercom:email-leak]` line with `leak_class == "external"` (a customer/third-party address the deterministic sanitizer already redacted to `support@muso.ai` BEFORE the reply shipped — the customer never saw it; an echo-hygiene lint, not a leak). Tone lint is not P0.

## Dimension A: Voice + leak audit

Mechanical scans are PRECOMPUTED — read the summary file, do NOT compose your own scan
OR aggregation (a hand-rolled scan, or a `group_by` over the rows WITHOUT `-s`, under
the pipeline's `set -euo pipefail` has aborted the whole run; the deterministic scripts
exist so this can't happen):
- `${WORKDIR}/voice-summary.txt` (from `scan-voice.sh`): the aggregate to read VERBATIM
  — per-marker dash tell totals, distinct-conv counts, the `top-dash-convs` repeat list,
  and `blacklist-total` / `blacklist-by-marker`. Use these numbers directly; never
  recompute them.
- `${WORKDIR}/voice-scan.jsonl` (from `scan-voice.sh`): the per-hit EVIDENCE behind the
  summary, one row per voice tell in a Caroline-authored body —
  `{kind:"dash", marker:"em-dash"|"en-dash", count}` dash occurrences and
  `{kind:"blacklist", marker}` phrase-blacklist hits (the blacklist is "Great question",
  "I understand your frustration", "investigate", "sorry the analytics are delayed",
  "sorry for the latency"). Read it only to cite an example `conv` id; never aggregate
  it by hand.
- Audit-line count from `audit.jsonl`. A `tool-leak`, or an `email-leak` whose
  `leak_class` is `internal` or `unknown` (fail closed — an unparseable email-leak
  line stays P0), is **P0** and the **top-line of the Slack post**. An
  `email-leak` whose `leak_class == "external"` is a **P2** echo-hygiene lint (🟡,
  no reviewer ping): the deterministic sanitizer already redacted the address to
  `support@muso.ai` before the reply shipped, so it is the email analogue of a
  reasoning-leak `action=stripped` (caught, not shipped) — never a customer-visible
  leak. Read `leak_class` from `audit.jsonl`; never the raw address (it is not emitted).

Score: 5 if zero leaks AND zero blacklist hits; -1 per blacklist hit (`blacklist-total`
in `voice-summary.txt`); floor 0.

## Dimension B: Tool usage + escalation hygiene

**Prereq-gated.** If `preflight.sh` reports `CV_TOOL_CTX_CONVERSATION_ID=unavailable`, skip this dimension and render "skipped: join-key prereq pending".

- For each conversation mentioning "analytics", "streams", "data", "updating": did Caroline call `profile_status` (joined by `conversation_id`)? If not, P1.
- For each `create_ticket` call: correct `actionType` + tier per `workspaces/support/TOOLS.md`?
- For each refund mention: was `refund-retention` 3-gate run first?
- Regression watch (P0 each) — `email support@muso\.ai`, `(contact|reach out to|email) support`:
  precomputed by `scan-tools.sh` into `${WORKDIR}/tools-summary.txt` (`regression-convs` = P0 count). Read that VERBATIM; do NOT re-derive the regex over `conversations.redacted.jsonl` — `redact.sh` rewrites `support@muso.ai` to `<email>`, so the literal can only match the RAW conversations (which `scan-tools.sh` scans). Hand-running it on the redacted file scores a silent false-clean.

Score: 5 if all expected `profile_status` calls fired AND no escalation mismatches AND no regression pattern.

## Dimension D: Customer sentiment

- Per-conversation: `resolved` | `escalated` | `frustrated` | `ghosted`.
- Explicit-frustration regex: "you're a bot", "are you actually checking", "this is useless", "human please", repeat-question-after-Caroline-reply.
- Top 3 frustration conversations cited (P2 each).

Score: 5 - frustration_count, floor 0.

## Dimension E: Reasoning-leak / guard health

Reports the health of the deterministic outbound reasoning-leak guard (PR #421) from TWO
independent sources. **Never conflate them.** "0 guard-log lines" does NOT mean "0 leaks";
it only means the guard caught nothing, which is reassuring ONLY when source 2 is also
zero. Always state both numbers.

**Source 1 (GUARD-CAUGHT)** -- `audit.jsonl` rows with `kind == "reasoning_leak"`
(`fetch-audit.sh`, from the edge `[intercom:reasoning-leak]` log):
- `action == "stripped"`: the guard cleaned the reply silently. Informational FYI, no severity.
- `action == "escalated"`: the guard suppressed the reply, reassigned to a human, and
  alerted. Cite each conv id + `reason`. Cross-reference `escalated-status.jsonl`: a conv
  with `human_replied == false` is an OPEN action item (**P1**) -- surface its `url`
  prominently. Escalated-and-answered is FYI.
- Group both by `markers` to show which leak shapes recur.
- **Evidence carve-out:** escalated conv ids come from the journal, NOT
  `conversations.jsonl` (the reply was suppressed, so the conv is absent from the fetch).
  Citing them is expected, not an evidence violation.

**Source 2 (GUARD-MISSED)** -- `shipped-leaks.jsonl` rows (`scan-shipped-leaks.sh`, which
scans SHIPPED Caroline replies for the guard's own INTERNAL+META_STRONG signatures). Each
hit is a leak that reached a customer AND a guard gap = **P0**. Quote the conv + the
matched `marker` so a new pattern can be added to `sanitize-reasoning-leak.ts`. **Do NOT
suppress a source-2 hit just because the same conv also appears in source 1** -- a stripped
conv whose cleaned reply still shipped a tell is a genuine "the strip was incomplete"
signal. That is precisely why the two sources are never conflated.

**Source caveat:** if `preflight` set `CAROLINE_REASONING_LEAK_SOURCE` to `syslog` or
`none`, source 1 is degraded (syslog has no precise window; `none` means unreadable). Say
so -- never present a zero caught-count from a degraded source as "healthy".

Score: 5 if source 2 is empty AND no escalated conv is unanswered; otherwise floored by the
P0/P1 findings above.

## "Good catches"

2–3 conversations where Caroline did particularly well. Cite the conversation_id and quote a single line. Subject to final-output redaction.

## Themes (cross-conversation recurrence)

The question the section answers for the reviewer: **did multiple customers say the
same thing this window?** Cluster semantically over the CUSTOMER parts of
`conversations.redacted.jsonl` (the transcripts are already fetched; do not re-fetch):

- `issue` — same bug / breakage / complaint ("credits not showing", "sync stuck").
- `question` — same how-do-I, asked independently (KB-gap signal).
- `feature_request` — same capability ask (product signal, not a support gap).
- `escalation_pattern` — same reason conversations end up needing a human.

Rules:

- Every member `conversation_id` must be real (validation hard-fails hallucinated
  ids). Do NOT pad a cluster with loosely-related convs to clear the threshold —
  `validate-digest.sh` recomputes `unique_customers` by `contact_id` dedupe and
  overwrites your count; a theme below 2 recomputed unique customers is dropped.
- Two convs from the SAME customer are one customer, not a theme.
- `label` is a short noun phrase; `summary` is one sentence of what customers are
  saying, in plain prose (no quotes needed; if quoting, one short fragment max).
- Weekly only: promote a theme to `kb_gap_candidates` when >=3 unique customers
  asked something the KB does not answer, and write `proposed_kb_note` — the exact
  text a human would paste into `workspaces/support/reference/*.md`. Validation
  fails any candidate whose recomputed count is < 3, and fails a DAILY digest
  carrying any candidates at all.

## Output: `${WORKDIR}/digest.json` (structured, machine-gated)

Do NOT assemble Slack text, header lines, links, or Block Kit — that is all
computed by `scripts/render-digest.py` from the validated digest. Write the
structured digest per `references/digest-schema.json` and hand it to
`scripts/publish-digest.sh` (see SKILL.md Phase 3).

What the deterministic renderer guarantees (so you don't have to):

- **Status emoji** 🔴/🟡/🟢 and the **P0 ping** (`<@U0AL36NADEY>` prepended ONLY
  when `severity.p0 > 0`) — computed from `severity`. `render-digest.py` is the
  single in-skill source of that Slack id.
- **Line 1** (emoji · title · date · window · `<N> convs` · `<p0> P0 / <p1> P1 /
  <p2> P2`) and **line 2** (`🎙️ Voice | 🛠️ Tools | 😟 Sentiment`) — the rendered
  fallback text still passes `assert-digest-contract.sh` as belt-and-braces.
- **Collapse-clean** — a dimension with no `findings` entries renders nothing;
  emit only real, non-zero findings (a quiet day is just headers + guard line).
- **Linkification** — cite BARE 15-16 digit conversation ids in every text field;
  the renderers wrap them into clickable Intercom links. Never write URLs.
- **Guard block always present** — from the `guard` object; state both sources
  even when zero (the two-source no-conflation rule), with the degraded-source
  caveat appended when `guard.source != "journalctl"`.

Rendering is **two Slack messages**: a lean main glance (P0/P1 action bullets
lead, under the ping; then header, compact scores, theme one-liners with
evidence links capped at 3) and a detail THREAD reply (P2 details, good
catches, full evidence lists, guard detail). The grader does not control the
split — it follows from `severity` and `dimension`.

What the grader still owes the digest:

- **Terse prose.** `findings[].text` and `themes[].summary` are one clause of
  ~12 words or fewer, rendered on a single bullet line. NO conversation ids
  in prose — evidence belongs in `conversation_ids` (the renderer strips
  stray ids from text mechanically, so an id written in prose simply
  disappears). Write P0/P1 `text` as an actionable clause ("internal email
  echoed into reply", not a narration) — it renders as a standalone action
  bullet at the very top of the post.

- `scores.tools` is `"skipped"` exactly when preflight said the join-key prereq is
  unavailable; never a bare dash, never a fabricated number (enforced both ways).
- Guard `items[]`: each escalated-and-still-unanswered conv (`unanswered_escalation`,
  P1 — cross-reference `escalated-status.jsonl`) and each guard-missed shipped leak
  (`shipped_leak`, P0) with the matched signature in `note`.
- `degraded[]`: name every degraded source (syslog/none guard log, fetch cap hit)
  — never present a zero count from a degraded source as healthy.
- Severity counts in `severity` match what the findings/guard items imply (the P0
  example below: the headline P0 is the guard-missed shipped leak — Dimension E
  drives severity, not just reporting).

### Worked example (P0 day, daily)

```json
{
  "kind": "daily", "date": "2026-06-04", "window_hours": 30, "conv_count": 31,
  "severity": {"p0": 1, "p1": 2, "p2": 2},
  "scores": {"voice": 4, "tools": 4, "sentiment": 4},
  "guard": {
    "caught_stripped": 3, "caught_escalated": 1, "missed_shipped": 1,
    "source": "journalctl", "shapes": ["looking-at-history", "tone-calibration"],
    "items": [
      {"type": "unanswered_escalation", "conversation_id": "215474520232724"},
      {"type": "shipped_leak", "conversation_id": "998877665544001", "note": "signature \"ready-to-output\""}
    ]
  },
  "findings": [
    {"dimension": "tools", "severity": "P1", "text": "1 missed profile_status", "conversation_ids": ["445566778899001"]},
    {"dimension": "voice", "severity": "P2", "text": "1 blacklist \"Great question\"", "conversation_ids": ["220033445566778"]},
    {"dimension": "sentiment", "severity": "P2", "text": "2 frustrated · top: \"this is useless\"", "conversation_ids": ["556677889900112"]}
  ],
  "themes": [
    {"category": "issue", "label": "Spotify-for-Artists sync stuck", "summary": "Releases not appearing after distributor confirms delivery.", "conversation_ids": ["445566778899001", "556677889900112", "220033445566778"], "unique_customers": 3}
  ],
  "kb_gap_candidates": [],
  "degraded": []
}
```
