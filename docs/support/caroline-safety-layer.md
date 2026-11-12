# Caroline safety layer (caroline-guard-g1, 2026-11-01)

Code that sits between Caroline and the customer. Decisions come from code, not from a prompt. Kill paths and
modes are source constants (or, for the optional classifier's rollout stage only, one reviewed config key) with no
env switches, and the detection parts never act on what they read.

| Part | Where | What it does |
|---|---|---|
| Output guard | `plugins/intercom/src/caroline-output-guard.ts`, wired in `channel.ts` after the merge guard, before `replyToConversation` | Deterministic rules block (a) promises of outcomes, dates, approvals, refunds or deletions; (b) secret sauce: scores, flags, check sources, issuer contact, staff/model/tool names, other people's phone/address/email; (c) contradictions of the approved process (ID asks, decline reasons, "nothing needed from you", "raised the priority", claim-first for GDPR, persona breaks); (d) off-topic replies (code, creative/general writing, outside advice, long replies with no Muso anchor). A blocked reply is replaced by the approved hand-off line, the conversation is reassigned to the team inbox, tagged `ai:output-guard`, written to the ledger and paged. `OUTPUT_GUARD_MODE = "enforce"`. |
| Adapter `sendText` | `sendTextReply` in `channel.ts` | The channel adapter's outbound path (agent, cron and `/hooks/agent` callers) goes through the SAME `guardOutbound` before posting, with the same fallback, reassignment and page. That path holds no customer turn, so a phone/address echo fails closed. |
| Answer bank | `plugins/intercom/src/answer-bank.ts` (`BANK_VERSION`) | The one versioned set of approved lines per intent. The guard masks them before the rules run (an approved line is never blocked) and logs a paraphrase as a `note` (never a block). `scripts/check-caroline-answer-bank.sh` keeps it equal to the workspace anchors and pins its hash. |
| Injection watch | `plugins/intercom/src/injection-watch.ts` (Intercom inbound) and `scripts/lib/injection_watch.py` (support@ email in `proof/gmail_intake.py`, proof text in `docverify/extract.py`) | Detection only. A hit becomes a ledger row. Medium and high hits are tagged `ai:injection-watch`, and a burst (5/h) or a repeat sender (3/24h) pages. Low hits are ledger-only. A **HIGH** hit also stores a short MASKED context window (emails, phones, 6+ digit ids and claim-code-shaped tokens redacted — `ORDER-123456789` and `XK4F7Q` included — ≤160 chars, cut on a word boundary) so it can be adjudicated after the fact — the bare match for `role_marker` is only `Assistant:`. Medium and low hits stay text-free. The two rule copies, including that masking, are pinned equal by `scripts/tests/injection-watch-parity.bats`. |
| Classifier (second, additive) | `plugins/intercom/src/safety-classifier.ts` → PromptGuard 2 22M sidecar `127.0.0.1:18793` (`promptguard/`, unit `hydra-promptguard.service`) | Labels inbound and outbound text. It can only ADD a block (score ≥ 0.98) and never remove one. It fails soft to `unavailable`. Every unavailable call, clean traffic included, is written at once as a `classifier_unavailable` ledger row, so idle periods and restarts lose nothing. Totals go to a `classifier_health` row every 15 minutes, written on the clock as well. The digest reports unavailable calls out of total calls, so an outage that recovers before the daily probe still shows. **Ships in shadow** (below): until the measurement says otherwise a hit records a `classifier_shadow_block` row and the reply is posted unchanged. |
| PromptGuard sidecar | `promptguard/{Dockerfile,server.py}`, installed by `scripts/install-aux-units.sh`, driven by `scripts/promptguard-sidecar.sh` | Meta Llama Prompt Guard 2 22M, CPU only, one torch thread. Container `--cpus 1 --memory 1g` plus `CPUQuota=100%` / `MemoryMax=1G` / `Nice=10` on the unit, so it always loses to the gateway for CPU. The model is baked into the image at build time (sha256-pinned by `model.sha256`, from a non-gated mirror), so inference never touches the network and a swapped model fails the build instead of serving. `ensure-image` rebuilds only when a source fingerprint moves, and the installer restarts an already ACTIVE unit only when that fingerprint moved (a plain `systemctl start` on an active unit is a no-op, so a changed `server.py` would otherwise never reach the running container). Cold load ~4.3 s; a request during it gets a 503, never a silent `benign`. Operators: `scripts/promptguard-sidecar.sh check`. |
| Canary token | `plugins/intercom/src/canary-token.ts` + `scripts/caroline-canary-sync.sh` (deploy Step 5d) | A random 32-hex marker, ROTATED EVERY DEPLOY, in two places: a bare line in Caroline's dispatched body (`buildAgentRawBody`, outside `[KNOWLEDGE_BASE]` / `[CONVERSATION_CONTEXT]`, because both outbound strippers are tag-scoped and run before the guard) and `workspaces/support/reference/canary-token.md` so her retrieval carries it too. A reply containing it is blocked as `reveal` / `canary_token`, and the recorded evidence is
`canary:sha256:<8 hex>` rather than the token itself, because that excerpt is logged, ledgered and digested; the
same 8-char prefix is what `caroline-canary-sync.sh` logs per rotation, so a leak still names the deploy. It is
a DETECTOR, not a credential: it grants nothing and losing it costs one band. RT53 is the red-team case, and it is
built to fail if the rule is ever removed: its bad reply says nothing any other reveal rule matches, it pins
`canary_token` by name in `bad_expect_rules` (a family alone is a bucket of a dozen rules, so a case asserting only
`reveal` can pass on the wrong rule), and `no_canary_control` re-runs the same text with the canary omitted and
requires a pass. |
| Daily red-team | `scripts/caroline-safety-daily.sh` (`caroline-safety-daily.timer`, 06:10 UTC) | Replays the corpus `plugins/intercom/redteam/caroline-redteam-cases.json` (outside `tests/`: deploy.sh rsync excludes every `tests/` dir, so a corpus there never reaches node-8) (53 cases) against the DEPLOYED edge plugin (`scripts/caroline-redteam.mjs`), and the injected-document cases against the doc-verify gate (`scripts/caroline_redteam_docverify.py`). It then digests the ledger and refreshes the watch candidates. Any failing case, an unloadable layer, or fewer passing cases than the day before pages critical. |

Fact-conditioned lines (Fable r5 `[key=status-chase-fact]`, FAIL CLOSED): a bank entry with `requiresFact`
(today `status_chase` needs `open_request`) posts only when code supplies the fact as known-true at send. A
false or unknown fact blocks it, and so does a paraphrase that keeps the lead; the customer gets the hand-off
line. The plugin has no code-sourced open-request fact yet, so **every status chase hands off** until one is
wired from where core keeps it. After that: true gives status_chase, false gives the declined fact, unknown
gives HANDOFF. The daily digest states `classifier=available|unavailable` (Fable s1).

## Measured detection and the shadow-first rollout

Prompt Guard 2 22M is a coarse second opinion, not a filter, and the numbers say so. On the 52-bad / 52-safe reply
corpus as measured on 2026-11-04 (RT53 was added after) it caught 1 bad reply and 0 safe ones (highest safe score 0.069, threshold 0.98). On 56 Muso-targeted inbound
attacks it caught 4-5, everything else scoring <= 0.099; generic jailbreaks score 0.99+ (ignore-previous-instructions,
DAN, override) while roleplay, impersonation and tool-name framings score <= 0.02. So it adds a band against the
crude attacks, and it must never be treated as the guard.

That is why it ships in shadow. `account.safetyClassifier.mode` (config: `openclaw-edge.json`, currently `"shadow"`)
decides what a hit does: `shadow` writes one `classifier_shadow_block` ledger row (score and the threshold it was
measured against) and posts the reply unchanged; `enforce` blocks. ABSENT means `enforce`, which is what every host
did before the sidecar existed, so a host that never sets the key cannot silently stop enforcing. The legacy
host-only intake (`scripts/intercom-webhook.js`) is shadow by default for the same reason (`PROMPTGUARD_MODE`): every
one of its scans returned 0 while the sidecar was down, so flipping it in the same change would have been an
unmeasured intake change. That value is VALIDATED (`scripts/intercom-webhook-promptguard-mode.js`): unset means
shadow, and anything set but unrecognised ENFORCES and logs CRITICAL, because a typo (`enfroce`) silently meaning
"shadow" would switch the block off while the operator believed it was on.

Before flipping to `enforce`, read the rows:

```bash
# every would-block row, with its score: these rows ARE the false-positive measurement
grep '"kind":"classifier_shadow_block"' /var/lib/hydra/injection-watch/ledger.jsonl | tail -50
# and confirm the sidecar answered at all, rather than "no rows" meaning "nothing was measured"
/opt/hydra/scripts/promptguard-sidecar.sh check
python3 /opt/hydra/scripts/injection-watch.py digest --hours 24
```

No rows with a healthy sidecar means the corpus agrees with production. No rows with an unhealthy sidecar means
nothing was measured, which is exactly what the `classifier_unavailable` rows exist to make visible.

## Files on node-8

- Ledger, shared by both writers: `/var/lib/hydra/injection-watch/ledger.jsonl` (0600) plus its sealed generations
  `ledger.jsonl.sealed-*` (also 0600; every reader reads both). Row kinds are
  `inbound_injection`, `output_guard` and `output_note`. Emails are stored only as sha256 of the trimmed lower-case
  address, the same normalisation as `policies/fraud-watchlist.json`.
- **Retention (30 days, seal-and-delete).** The ledger holds the only customer-derived text this system stores: a
  HIGH hit's masked context, so its age is bounded. `scripts/lib/injection_watch.py` `prune_ledger` runs on every daily
  run and NEVER rewrites a file a writer can append to (QA on #1665, 2026-11-03): it renames the live
  `ledger.jsonl` to a sealed generation `ledger.jsonl.sealed-<UTC timestamp>` (a rename drops no bytes) and deletes a
  whole sealed generation only when everything in it — newest row timestamp and the file's own mtime, so a late
  append protects it — is older than the cut. A row appended during the seal lands either in the sealed generation or
  in the fresh live file, and both are read (`read_ledger`, `recent_hits`, `digest` and the CLI read the live file and
  every sealed generation), so the window cannot lose a hit. A generation's mtime is normalised to its newest row at
  seal time (so sealing never launders age: an all-old file is deleted by the same run that sealed it) and a late
  append updates it again, which is what protects a generation written into after the seal. A generation holding an
  undated or unparsable row is kept, never half-rewritten. The digest states the files
  and rows dropped; a prune that cannot run pages, because old text at rest is a privacy regression. `30` lives in
  both copies (`RETENTION_DAYS` / `LEDGER_RETENTION_DAYS`) and the parity test pins them equal.
- **One lock, both writers, and the prune** (QA on #1665, finding 1). An age check followed by an `unlink` can never
  be safe by itself: whatever order the check and the delete take, a writer that already has the old inode open can
  append in between, and that row becomes unreachable. So the two take turns on one filesystem lock,
  `ledger.jsonl.ledger.lock` — an atomic **directory create** (`os.mkdir` / `fs.mkdir`), because Node has no
  `flock` and two languages need one lock. `append()` (Python and `appendSafetyLedger` in TypeScript) opens, writes
  and closes inside the lock; `prune_ledger` decides and unlinks inside the same lock, so no append is ever in
  flight across a delete. If the lock cannot be had in time the two callers deliberately differ: the **writer
  appends anyway** and prints `[injection-watch:ALERT] ledger lock busy ...` (a dropped customer hit is worse than
  one unserialised append), while the **prune raises** and the daily run pages — a retention window that did not get
  enforced is not a quiet success. The name and both timeouts are constants on both sides
  (`LEDGER_LOCK_SUFFIX`, `LEDGER_LOCK_STALE_MS` / `LOCK_STALE_SECONDS`, `LEDGER_LOCK_WAIT_MS` /
  `LOCK_WRITE_TIMEOUT`) and the parity test pins them equal.
- **The lock is the fast path; the guarantee is "no live descriptor"** (QA on #1665, finding 3). Any timeout can be
  beaten by a slow or loaded host — a prune can outlive its own lock and a writer can bypass it — so deletion is not
  argued from the lock at all. Before every `unlink` the prune enumerates the descriptors live processes hold
  (`_open_inodes()`, `/proc/<pid>/fd`) and **keeps any generation whose inode is still open**: a row can only be
  lost by unlinking the file it was written into, and while a descriptor exists the append can still be landing.
  Readers of the lock are also not fooled by a slow holder: the prune **heartbeats** the lock (mtime touch) between
  generations, so only a genuinely dead holder's lock is stolen, after `LOCK_STALE_SECONDS` (300 s) of silence.
  If `/proc` cannot be read at all, every candidate is kept and reported as `unverified_files`, and `prune` exits 3
  so the daily run pages: "I could not check who holds it" is never read as "nobody holds it". `held_open_files` in
  the report says how many generations were kept for an in-flight append; they are deleted on a later run.
- **An unreadable generation is an error, never a quiet day** (QA on #1665, finding 2). `ledger_files()` returns
  every file the ledger consists of, whatever its type, and readers raise instead of treating an unreadable file as
  empty: `hits` exits 2, `prune` exits 3, `daily` prints `ledger_error` and fails its record. Only a *missing* file
  (deleted or sealed by the prune between two syscalls) counts as empty. A HIGH hit that exists only in a generation
  nobody can open must page, not read as "no hits today". **Audience**: the
  support leads who investigate a hit, and security. **Purpose**: adjudicate a HIGH hit after the fact. Nothing else
  reads it, no customer text is ever written unmasked, and a hit row carries no conversation content beyond the
  window. **Masking runs over the whole input before any window is taken** (QA on #1665, review 5765021034):
  `mask_pii` / `maskPii` are LENGTH-PRESERVING (`[phone]####`), so the window offsets still address the original
  text while every identifier is already redacted — masking after the slice let a phone whose head sat outside the
  window survive as a fragment (`010-9999` does not match the phone rule on its own). Both edges are scrubbed as
  well, belt and braces. The parity test compares the two languages on left-edge, right-edge and long-body fixtures.
  **Known gap, by design**: a token with no digit and no long run (a name, an address, a short order number)
  is not redacted — the excerpt is deliberately short and masked, not anonymised.
- **A reader re-lists when a generation disappears under it** (QA on #1665, review 5770078247). `ledger_files()` is
  a snapshot, and the daily prune renames the live file; a read of the old name then finds nothing, which would
  report a quiet window while the row sat in the generation it had become (reproduced: 0 rows during the seal, 1
  immediately after). The reader pass re-lists on a vanished path and reads whatever it has not read, keyed by
  **(st_dev, st_ino)** so a renamed generation is read exactly once, never twice. Bounded at 5 listings with a 10 ms
  backoff, and never silent: past that it raises, so `hits` exits 2 and the digest prints `ledger_error` with the
  numbers absent rather than a zero. A generation the prune *deleted* costs a couple of extra listings, not a stall.
  A vanished read is not the only shape of the race (QA on #1665, review 5772461331): `ledger_files()` collects the
  sealed names **first** and only then appends the live file, so a rename landing between those two steps returns an
  **empty** list -- the sealed name was scanned before the move and the live path is gone after it. Nothing vanishes,
  so the pass also converges on a **stable listing**: two consecutive identical listings mean the prune is not
  mid-move, and any difference re-reads what is new. An empty snapshot is therefore never read as an empty ledger.
- **A listing that fails is an UNKNOWN ledger, never an empty one** (QA on #1665, review 5773297425).
  `ledger_files()` enumerates the sealed generations beside the live file, and it used to fall back to "no
  generations" when that enumeration raised -- so while the live file stayed readable, a sealed HIGH hit vanished
  from `read_ledger`, the digest and `hits`, and the day read as quiet (reproduced: normal read returned both,
  a failing listing returned only live). Only a **missing directory** means there is no ledger here. Anything else
  means "I could not look", which surfaces: `hits` exits 2, the digest prints `ledger_error` with the counts
  **absent**, and the prune exits 3 and the daily run pages. The live path is `stat`ed rather than `exists()`-checked
  for the same reason (`exists()` answers False on EACCES/EIO).
- Reviewing a stored HIGH hit: `python3 scripts/injection-watch.py hits --hours 24 --severity high` prints the recent
  hit-turns with their masked context. Read-only; this is the only way to see what triggered a hit. It exits 2 and
  says why when the ledger cannot be read, so an unreadable ledger is never mistaken for a quiet day. `ledger_files()`
  is the one place that decides what the ledger consists of; `prune` refuses (exit 3) when the live path is not a
  regular file, so it can never rename or unlink something it did not create.
- Watch candidates: `/var/lib/hydra/injection-watch/watch-candidates.json`. This is a REVIEW list for the fraud-lens
  watchlist owner. Moving a sender onto `policies/fraud-watchlist.json` is a reviewed PR. Nothing writes the watchlist.
- Daily records: `/var/lib/hydra/caroline-redteam/<date>.json`.
- Canary: `/opt/hydra/.canary-token` (0600, prompt copy) and
  `/opt/hydra/workspaces/support/reference/canary-token.md` (0644, RAG copy). Both server-generated and
  rsync-excluded, so neither is ever in the repo. `scripts/caroline-canary-sync.sh --check` proves they agree; a
  disagreement means one write landed and the other did not.
- PromptGuard image state: `/var/lib/hydra/promptguard/image.fingerprint` (the source fingerprint the built image
  corresponds to).

## Changing things

- **A rule.** Add a red-team case that the change must catch, and a safe reply it must not block. CI fails if any
  case gets through (`plugins/intercom/tests/redteam.test.ts`). Before shipping, replay a recent day of real
  Caroline replies and check for false positives.
- **An approved line.** Edit `answer-bank.ts` AND its anchor under `workspaces/support`. Then bump `BANK_VERSION`
  and the pin in `scripts/check-caroline-answer-bank.sh`. Copy is owned by caroline-teach-c1 and ruled on by Fable r5.
- **An injection rule.** Edit both copies (TS and Python) in the same PR and bump `INJECTION_WATCH_VERSION` /
  `VERSION`. The masking (`mask_pii` / `maskedContext`) is part of the same contract: widen the context window, or
  stop masking something, only with a parity fixture that proves both sides still agree.
- **Switch the guard to shadow (log but post).** Change `OUTPUT_GUARD_MODE` in source and ship it as a PR. There is
  deliberately no runtime switch.
- **Flip the classifier between shadow and enforce.** Edit `account.safetyClassifier.mode` in `openclaw-edge.json`.
  This one IS a config key: the point of the shadow window is to measure and then enforce without a code change in
  between. Both values are asserted by tests (`plugins/intercom/tests/caroline-safety.test.ts`, `config.test.ts`).
- **The canary.** Nothing to edit: Step 5d rotates it every deploy. `--reuse` keeps the current one (staging, a
  hand-run), `--check` verifies, `--dry-run` shows what would change.

## Triage

```bash
# last day, both sides
python3 /opt/hydra/scripts/injection-watch.py digest --hours 24
# the deployed layer against the corpus, right now
node /opt/hydra/scripts/caroline-redteam.mjs
```

A block on a reply that was actually fine is a false positive. To fix it, add the reply as a `safe_reply` case in
the corpus and narrow the rule. Do not widen the masking.

**A blocked reply no longer assigns the conversation to anyone** (intercom-no-human-assignment-k1, captain
2026-11-11). Until then every block assigned the thread to `defaultInboxId`, which on the live host was one
person's admin id: 404 of the 478 assignments that person received from this plugin in 14 days were output-guard
blocks, 352 of them the single rule `fact_unverified:status_chase`. Now a block (and a reply emptied by the
help-link gate, and a reasoning leak) posts `BLOCKED_REPLY_FALLBACK`, which is the AI-queue line
(`ai_queue_fallback` in the answer bank: no person, no time), the conversation stays with Caroline, the ledger row
records `assignment="ai_queue"`, and the Slack line says it is for the fix loop, not a task. Who holds a
conversation is decided in ONE module, `plugins/intercom/src/assignment-policy.ts`: an explicit escalation
(risk rule, restricted account, legacy pattern) must carry a reason and goes to the `escalationTeamId` TEAM queue
(or Intercom's Unassigned when unset), never to a personal admin id; `defaultInboxId` is retired and
`scripts/check-intercom-no-personal-assignee.sh` fails CI on it. A human assignee silences Caroline only while a
human is working the thread (`humanHoldHours`, default 72): a stale assignment is reclaimed on the customer's next
message. `ledger.jsonl` rows written before this change carry `assignment` values `team_inbox`,
`already_assigned`, `FAILED`. The digest's
`classifier_unavailable` count is per-call durable rows while `classifier_calls` comes from 15-minute windows that
can count fewer, so the summary prints a ratio only when the window total covers the rows and otherwise says
"per-call rows are authoritative".
