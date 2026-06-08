# Caroline Daily Review: Grading Rubric

Every dimension scores 0-5. P0/P1/P2 severity per finding. P0 in any dimension forces the Slack headline.

Daily pulse: dimensions A (voice + leak), B (tools), D (sentiment), E (reasoning-leak / guard health). KB-gap detection (the old Dimension C) and auto-PR are deferred to the separate weekly KB roll-up; do not cluster KB gaps or open PRs from the daily run.

## Severity ladder

- **P0**: any `[intercom:tool-leak]` / `[intercom:email-leak]` audit line in window, OR any regression pattern from Dimension B (analytics→email/support loop), OR a SHIPPED reasoning leak the guard missed (Dimension E, source 2: a reply that reached a customer).
- **P1**: wrong escalation, wrong actionType/tier, missed required `profile_status` call on an analytics/streams conversation, refund 3-gate skipped, OR an ESCALATED reasoning-leak conv with no human reply yet (Dimension E: a customer is waiting on a human).
- **P2**: voice blacklist hit ("Great question", em-dash, "investigate", apologies-for-analytics), sentiment issue. Tone lint is not P0.

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
- Audit-line count from `audit.jsonl`. Any non-zero is the **top-line of the Slack post**.

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

## Slack output template (glanceable daily digest)

Assemble the digest, then pipe it through `redact-output.sh` and finally through
`assert-digest-contract.sh` (the mechanical header guard) before emitting it as the
final assistant message:

```
<assemble review text> | scripts/redact-output.sh | scripts/assert-digest-contract.sh
```

### Header contract (MUST be present every run, on every model)

Hard, non-negotiable minimum. `assert-digest-contract.sh` fails the run if either
line is missing, so emit both even on a clean, quiet day:

- **Line 1** MUST contain, in order: a status emoji, the date, the window phrase
  (mirror the fetch window: "last 30h"), the conversation count as `<N> convs`, and
  the severity triplet `<p0> P0 / <p1> P1 / <p2> P2` with zeros included.
- **Line 2** MUST contain the three scores: `Voice <0-5> | Tools <0-5 or skipped> | Sentiment <0-5>`.

Rules:

- **Status emoji**: 🔴 if any P0; 🟡 if any P1 and no P0; 🟢 otherwise.
- **P0 ping**: prepend the literal `<@U0AL36NADEY>` to line 1 ONLY when P0 count > 0.
  No mention on a no-P0 day (a daily digest must not ping every morning). This
  template is the only in-skill source of that Slack id.
- **Tools skipped**: when `preflight.sh` reports `CV_TOOL_CTX_CONVERSATION_ID=unavailable`,
  render the token as `skipped` (e.g. `Tools skipped`); never a bare dash, never a
  fabricated number. (`redact-output.sh` rewrites any em/en-dash to a hyphen, so a
  dash placeholder is ambiguous next to a numeric score.)
- **Collapse clean dimensions**: applies to DETAIL bullet lines only, never to the two
  header lines. Print a detail bullet only when it has a real, non-zero finding; omit
  zero-count metric bullets. A perfectly clean day is just the two header lines (plus,
  optionally, a "Good catch" bullet).
- **Conversation ids**: cite the real Intercom `conversation_id` (a 15-16 digit
  number, which survives output redaction) so a reader can open the thread.
- **Reasoning-leak guard block** (Dimension E): ALWAYS present (it is what makes
  `assert-digest-contract.sh`'s `guard` check pass). When everything is zero, collapse it
  to one line: `Reasoning-leak guard: healthy - 0 caught, 0 missed in shipped replies.`
  When there are findings, lead with `Reasoning-leak guard (last 30h):` then bullets:
  caught counts (`N stripped (silent), M escalated -> human` with `[shapes: ...]`); each
  escalated-and-still-unanswered conv as an action item with its URL; and each SHIPPED leak
  the guard missed as `conv <id> signature "<marker>"` (a guard gap). State both the caught
  count AND the missed count even when one is zero. Append the source caveat when degraded.

### Quiet day (the common case, no ping)

```
🟢 Caroline daily · Wed Jun 4 · last 30h · 23 convs · 0 P0 / 0 P1 / 1 P2
Voice 5 | Tools 5 | Sentiment 4
• Sentiment: 1 frustrated · conv 215474545718046 "are you actually checking?"
• Good catch: conv 998877665544001 · clean refund-gate run
Reasoning-leak guard: healthy - 0 caught, 0 missed in shipped replies.
```

### P0 day (rare, pings the reviewer)

```
<@U0AL36NADEY> 🔴 Caroline daily · Wed Jun 4 · last 30h · 31 convs · 1 P0 / 2 P1 / 2 P2
Voice 4 | Tools 4 | Sentiment 4
Reasoning-leak guard (last 30h): 3 stripped (silent), 1 escalated -> human. [shapes: looking-at-history, tone-calibration]
  • Escalated & still unanswered: conv 215474520232724 (https://app.intercom.com/a/inboxes/all/conversations/215474520232724)  <- action item (P1)
  • SHIPPED leak the guard missed: conv 998877665544001 signature "ready-to-output"  <- guard gap (P0)
*Tools (4):* 1 missed profile_status · conv 445566778899001 (P1)
*Voice (4):* 1 blacklist "Great question" (conv 220033445566778)
*Sentiment (4):* 2 frustrated · top: conv 556677889900112 "this is useless"
```

(In the P0 example the headline P0 is the guard-missed shipped leak, and one P1 is the
unanswered escalation -- Dimension E is driving the severity, not just reporting.)
