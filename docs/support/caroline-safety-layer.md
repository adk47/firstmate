# Caroline safety layer (caroline-guard-g1, 2026-11-01)

Code that sits between Caroline and the customer. Decisions come from code, not from a prompt. Kill paths and
modes are source constants with no env switches, and the detection parts never act on what they read.

| Part | Where | What it does |
|---|---|---|
| Output guard | `plugins/intercom/src/caroline-output-guard.ts`, wired in `channel.ts` after the merge guard, before `replyToConversation` | Deterministic rules block (a) promises of outcomes, dates, approvals, refunds or deletions; (b) secret sauce: scores, flags, check sources, issuer contact, staff/model/tool names, other people's phone/address/email; (c) contradictions of the approved process (ID asks, decline reasons, "nothing needed from you", "raised the priority", claim-first for GDPR, persona breaks); (d) off-topic replies (code, creative/general writing, outside advice, long replies with no Muso anchor). A blocked reply is replaced by the approved hand-off line, the conversation is reassigned to the team inbox, tagged `ai:output-guard`, written to the ledger and paged. `OUTPUT_GUARD_MODE = "enforce"`. |
| Adapter `sendText` | `sendTextReply` in `channel.ts` | The channel adapter's outbound path (agent, cron and `/hooks/agent` callers) goes through the SAME `guardOutbound` before posting, with the same fallback, reassignment and page. That path holds no customer turn, so a phone/address echo fails closed. |
| Answer bank | `plugins/intercom/src/answer-bank.ts` (`BANK_VERSION`) | The one versioned set of approved lines per intent. The guard masks them before the rules run (an approved line is never blocked) and logs a paraphrase as a `note` (never a block). `scripts/check-caroline-answer-bank.sh` keeps it equal to the workspace anchors and pins its hash. |
| Injection watch | `plugins/intercom/src/injection-watch.ts` (Intercom inbound) and `scripts/lib/injection_watch.py` (support@ email in `proof/gmail_intake.py`, proof text in `docverify/extract.py`) | Detection only. A hit becomes a ledger row. Medium and high hits are tagged `ai:injection-watch`, and a burst (5/h) or a repeat sender (3/24h) pages. Low hits are ledger-only. The two rule copies are pinned equal by `scripts/tests/injection-watch-parity.bats`. |
| Classifier (optional, second) | `plugins/intercom/src/safety-classifier.ts` → PromptGuard sidecar `127.0.0.1:18793` | Labels inbound and outbound text. It can only ADD a block (score ≥ 0.98) and never remove one. It fails soft to `unavailable`. Every unavailable call, clean traffic included, is written at once as a `classifier_unavailable` ledger row, so idle periods and restarts lose nothing. Totals go to a `classifier_health` row every 15 minutes, written on the clock as well. The digest reports unavailable calls out of total calls, so an outage that recovers before the daily probe still shows. The sidecar is **not deployed** on node-8 as of 2026-11-01. |
| Daily red-team | `scripts/caroline-safety-daily.sh` (`caroline-safety-daily.timer`, 06:10 UTC) | Replays the corpus `plugins/intercom/redteam/caroline-redteam-cases.json` (outside `tests/`: deploy.sh rsync excludes every `tests/` dir, so a corpus there never reaches node-8) (52 cases) against the DEPLOYED edge plugin (`scripts/caroline-redteam.mjs`), and the injected-document cases against the doc-verify gate (`scripts/caroline_redteam_docverify.py`). It then digests the ledger and refreshes the watch candidates. Any failing case, an unloadable layer, or fewer passing cases than the day before pages critical. |

Fact-conditioned lines (Fable r5 `[key=status-chase-fact]`, FAIL CLOSED): a bank entry with `requiresFact`
(today `status_chase` needs `open_request`) posts only when code supplies the fact as known-true at send. A
false or unknown fact blocks it, and so does a paraphrase that keeps the lead; the customer gets the hand-off
line. The plugin has no code-sourced open-request fact yet, so **every status chase hands off** until one is
wired from where core keeps it. After that: true gives status_chase, false gives the declined fact, unknown
gives HANDOFF. The daily digest states `classifier=available|unavailable` (Fable s1).

## Files on node-8

- Ledger, shared by both writers: `/var/lib/hydra/injection-watch/ledger.jsonl` (0600). Row kinds are
  `inbound_injection`, `output_guard` and `output_note`. Emails are stored only as sha256 of the trimmed lower-case
  address, the same normalisation as `policies/fraud-watchlist.json`.
- Watch candidates: `/var/lib/hydra/injection-watch/watch-candidates.json`. This is a REVIEW list for the fraud-lens
  watchlist owner. Moving a sender onto `policies/fraud-watchlist.json` is a reviewed PR. Nothing writes the watchlist.
- Daily records: `/var/lib/hydra/caroline-redteam/<date>.json`.

## Changing things

- **A rule.** Add a red-team case that the change must catch, and a safe reply it must not block. CI fails if any
  case gets through (`plugins/intercom/tests/redteam.test.ts`). Before shipping, replay a recent day of real
  Caroline replies and check for false positives.
- **An approved line.** Edit `answer-bank.ts` AND its anchor under `workspaces/support`. Then bump `BANK_VERSION`
  and the pin in `scripts/check-caroline-answer-bank.sh`. Copy is owned by caroline-teach-c1 and ruled on by Fable r5.
- **An injection rule.** Edit both copies (TS and Python) in the same PR and bump `INJECTION_WATCH_VERSION` /
  `VERSION`.
- **Switch the guard to shadow (log but post).** Change `OUTPUT_GUARD_MODE` in source and ship it as a PR. There is
  deliberately no runtime switch.

## Triage

```bash
# last day, both sides
python3 /opt/hydra/scripts/injection-watch.py digest --hours 24
# the deployed layer against the corpus, right now
node /opt/hydra/scripts/caroline-redteam.mjs
```

A block on a reply that was actually fine is a false positive. To fix it, add the reply as a `safe_reply` case in
the corpus and narrow the rule. Do not widen the masking.
