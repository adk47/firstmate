# Making silent QA-review loss impossible to miss

**Date:** 2026-08-13
**Status:** implemented (reconciler + sweep fix); deploy-side change deliberately NOT taken — see §6
**Unblocks:** `policies/qa-approval-policy.json` → `_field_notes.merge_gate_repos_INTENTIONALLY_EMPTY`

## 1. The loss

Hydra's QA auto-review lane loses reviews **silently**. Dispatch succeeds, the ack
comment posts, the one-shot cron is created — and then the review is destroyed and
reaped as if it had succeeded. No error, no page, no retry, no trace.

The mechanism, in order:

1. **The qa lane serializes.** Every diagnostic in the window reads
   `queueDepth=1 reason=queued_behind_active_work`. Reviews take 2-6 min each, so a
   batch of dispatches queues.
2. **A gateway restart kills what is queued.** journald on node-8:
   `[gateway] draining 18 active task(s) and 8 active embedded run(s) before restart
   with timeout 0ms` → `forced restart requested; skipping active work drain` →
   `[shutdown] aborted 6 active run(s) during restart shutdown`.
3. **openclaw does not re-arm a past-due one-shot `at` cron across a restart.** The
   killed job left zero journal lines, zero `agent:qa:cron:` session keys, and no
   session file at all. (A turn that dies mid-flight leaves a truncated session; this
   left nothing.) Inferred from total absence, not from reading openclaw source.
4. **The stale sweep then deletes the never-fired row.** `qa-dispatch-pr-review.sh`
   deleted any `qa-autoreview-pr-*` job with `createdAtMs < now-3600000`, on the stated
   premise that "a job created >1h ago is definitely done". That is an **elapsed-time
   test, not a completion test**. A job that queued rather than ran was deleted before
   ever firing, and `cron get <uuid>` then answered `cron job not found`. The evidence
   is erased.

Confirmed blast radius: `muso-skills#2` (created 17:11:10Z, killed by the 17:17:14Z
restart while queued behind `platform-ticker#39`, swept ~18:24Z, sat 18h until a human
re-dispatched); `core-backend#9243` (acked 2026-07-29T13:28Z, **no verdict for 15
days**, verdict landed in ~5 min once re-dispatched — proving the loss class long
predates the 08-12 deploy).

## 2. Two premises in the original write-up were wrong

Both were checked against the code and the live box before designing, and both changed
the design.

**The ack does NOT carry the head sha.** The marker is only
`<!-- hydra-qa-ack owner/repo#N -->` (`.github/workflows/external-pr-review.yml:100`);
the sha appears in the comment *body*, on a different line from the marker. The
"join key already exists" assumption is false. Worse, the ack step is
`continue-on-error: true` and always `exit 0` — it is best-effort by construction, so
**ack-absence does not mean "not dispatched"**. Any rule of the form "ack present and
no verdict = lost" is therefore fail-*open* on every PR whose ack write failed.

Measured on the live org: only ~24% of open PRs across the allowlisted repos carry an
ack at all. An ack-keyed reconciler would have shipped as a near-no-op.

**Hydra's deploy DOES drain.** `scripts/lib/gateway-restart.sh` implements
`openclaw gateway restart --safe` against a real `GATEWAY_DRAIN_DEADLINE_SECS=390`
budget, and `drain_restart_gateway` falls back to a hard `systemctl restart` only when
`HYDRA_HARD_RESTART=1`, no verified pre-request MainPID, the safe request fails, or the
drain exceeds 390s — and it already Slack-notifies on every fallback. The journald
`timeout 0ms` / `skipping active work drain` lines are what openclaw logs when the hard
SIGTERM path hits it. So the 08-12 loss happened on the *fallback* path, not because
the deploy never drains.

## 3. Mechanism decision: systemd timer, not an openclaw cron

CLAUDE.md's decision tree item 3 says "wall-clock schedule, no human in the loop →
openclaw cron". **That is not the right read here**, and item 3 should be understood as
carrying an unstated precondition: *the work runs inside a gateway agent turn*.

The reconciler is a **systemd timer on node-8**, installed by
`scripts/install-aux-units.sh`. Three independent reasons, any one sufficient:

- **It must survive the event it detects.** An openclaw cron lives in the gateway
  process; the restart that destroys queued QA reviews would destroy the detector too.
  A detector sharing the failure domain of the thing it detects is structurally broken.
- **No LLM turn is needed** — it is `gh` + `jq` + bash. Routing it through the `qa`
  agent would make it compete for the very serialized lane it exists to protect.
- **It needs `gh` as org-admin `adk47`**, which is only true on node-8. That is a
  host-bound credential — a timer property, not a gateway-cron property.

GitHub Actions is ruled out by CLAUDE.md's "GH Actions for runtime ops (as opposed to
CI gates) → has caused two-CD-paths drift before". This is runtime ops.

Precedent for the timer route with agent-free scheduled scripts is already dense in
this repo: `hydra-release.timer`, `codex-token-refresh.timer`,
`intercom-intake-watchdog.timer`, `overdue-verification-notifier.timer` — all
heredoc'd in `install-aux-units.sh`. Durable state goes in `/var/lib/hydra/`, outside
the rsync tree, the same reason `codex-active-account` lives there.

## 4. Expectation comes from PR properties, never from the ack

Given §2, the reconciler derives "a review was expected" from the PR itself:

> open, not draft, base ref gated for that repo, and the author resolves to a Slack UID.

It computes that by **calling the dispatch path's own predicate scripts**
(`qa-external-repo-allowlist.sh`, `qa-author-slack-uid.sh`) rather than reimplementing
them — a drifted copy of a scope rule would reopen the race it exists to close. Note
the gated bases genuinely differ and must not be averaged: hydra is `main` only
(`qa-autoreview.yml:135`), external repos accept `develop`/`main`/`master`
(`external-pr-review.yml:161`).

A **verdict** exists for the current head sha if either a bot PR review carries
`commit_id == head` (bot logins read from the policy's `.identity.bot_logins`, never
hardcoded) or a terminal `qa-review` commit status is present. `pending` is not a
verdict. The head sha is re-resolved every tick, never cached across ticks.

The ack survives as **diagnostic text only** — "ack present at T" vs "no ack, dispatch
may have been dropped upstream" — printed into the page, never used in a decision.

This has a free bonus: property-derived expectation also catches the `#214` class where
GitHub accepts a `repository_dispatch` (HTTP 204) and never creates a run — no ack, no
cron, no run, invisible to any ack-join design. That class was previously handled by a
*human* resender protocol; the reconciler retires it, and re-dispatches by calling
`qa-dispatch-pr-review.sh` directly on the box, bypassing the flaky transport.

## 4a. The age bound — why property-derived expectation needs two floors

Property-derived expectation has one cost that must be paid explicitly: because it
deliberately ignores the ack, it **cannot distinguish "never dispatched because the
lane did not exist yet" from "dispatched and lost"**. Rehearsing the ratified predicate
read-only against the live org from node-8 made that concrete:

```
repos=17  expected=154  no-verdict=59
```

with ages from 131h up to **7106h (296 days)** — `web-credits#1875`,
`platform-ticker#6..#15`, `H-DevOps#1286..#2342`. Those are pre-lane PRs: the external
allowlist grew one repo at a time, and `muso-skills` + `platform-ticker` were onboarded
only on 2026-08-12 (#822), `analytics-controller` in #820. Shipped without a bound, the
first tick would re-dispatch to the global cap and keep doing so every 15 minutes for
days, saturating the serialized qa lane with reviews of ten-month-old PRs — worse than
the loss it fixes.

The bound is **two floors**, and the watermark is deliberately **per-repo**:

> act iff `trigger_time >= max(repo_epoch_ms, now − 14d)`

- **Per-repo epoch** = the first tick at which that repo appears in
  `qa-external-repo-allowlist.sh --list`. A single global "first run" watermark would
  fix only the initial rollout; every *future* onboarding would re-flood, because that
  repo's pre-lane PRs postdate the reconciler's first run. Per-repo epochs are
  self-installing, need no git archaeology, and match lane semantics exactly: a pre-lane
  PR that gets pushed after onboarding receives a real dispatch *and* crosses its epoch.
- **14-day ceiling** is the belt against a watermark bug or state loss. It matters
  because a *missing* state file is treated as a normal first run (only an *unparseable*
  one refuses) — so without the ceiling, deleting the state file would re-flood.
- **Trigger time is `max(last head push, last ready_for_review transition)`**, not head
  push alone: a dispatch lost on a ready-for-review event against an older head would
  otherwise be permanently invisible. The timeline lookup is lazy — only for non-draft
  PRs the head-push bound would exclude — and cached per PR on `updatedAt`.
- **A future-dated head commit is discarded, never clamped.** The head-push timestamp
  comes from `commit.committer.date`, which is author-controlled (`GIT_COMMITTER_DATE`).
  An earlier version of this bound clamped a future date down to `now`, which re-clamped
  on every tick (since `now` keeps advancing too) — that permanently restarted the grace
  window and made the PR un-reconcilable forever. The fix: a committer date that postdates
  `now` is treated as unusable and dropped entirely, falling back to the PR's `createdAt`
  (GitHub-, not author-, controlled) for the head-push floor.

The pre-epoch exclusion is reported as **one summary line per tick** (count, repo
spread, oldest age), never per-PR and never a page. Silent truncation would read as
"covered everything".

Consequence, stated plainly: the pre-existing backlog — the `core-backend#9243` class —
is **not** healed automatically. It needs one human sweep at rollout, for which that
summary line is the worklist.

**Verified steady state** (read-only rehearsal from node-8, 2026-08-13, bounds applied,
correct jq parameterisation):

```
repos=17  ceiling=14d  expected=37  no-verdict=4  readfail=0
```

All four carry **no ack comment at all**, i.e. they were never dispatched rather than
dispatched-and-lost: `platform-ticker#37`/`#38` (repo onboarded 2026-08-12, PRs last
touched 08-07/08-08 — pre-epoch), `H-DevOps#2342`, `tests-web-e2e#254`. Under the
per-repo epoch every one of them is correctly suppressed, so the expected
false-positive rate at rollout is zero and the reconciler starts quiet. That is the
result the bound exists to produce; without it the same run reported 59.

## 4b. Two API traps that fail toward mass re-dispatch

Both were hit while rehearsing, and both are silent:

- **`gh api` has no `--arg`/`--argjson`** — its only jq surface is `-q/--jq <string>`.
  Passing `--argjson` exits 1 with a usage dump; wrapped in `2>/dev/null || true`, that
  becomes an empty result that reads as "no bot review found", classifying every healthy
  PR as lost. Fetch with `gh api`, then pipe into standalone `jq` for parameterised
  queries, and check rc separately (a jq compile error exits 3).
- **Bot logins must be matched by literal equality, never jq `test()`/`match()`.**
  `.identity.bot_logins` contains `muso-qa-bot[bot]`, and `[bot]` is a regex character
  class.

The general rule the reconciler enforces: **no failed API read may collapse into a value
that means "no verdict"**. Every `gh` call whose emptiness would push a PR toward "lost"
checks its rc and routes to the read-failure path (counted, paged after N consecutive
whole-tick failures) rather than to a default. This is the highest-severity failure mode
in the design, because it fails toward mass re-dispatch on a serialized lane.

## 5. The sweep now tests completion, not elapsed time

Run evidence is nested under `.state` in `cron list --all --json` on openclaw 2026.7.1
(**verified live on node-8** — there are no top-level `lastRunAtMs`/`lastStatus`
fields, which is what a naive port of this fix would reach for and silently get `null`
from):

| job state | shape |
|---|---|
| queued, never run | `.state.nextRunAtMs` only |
| running | `.state.runningAtMs` present, `.status == "running"` |
| completed ≥1 run | `.state.lastRunAtMs`, `.state.lastStatus`, `.state.lastRunStatus` |

Rules: delete iff `.state.lastRunAtMs` is present and older than the 1200s job timeout
plus margin. A job that has **never run is never deleted at any age**. A running job is
never deleted. This encodes "cannot still be running" directly, and unlike a raised
`createdAt` cutoff it cannot reap a job that queued for an hour and only just started.

Two adjacent bugs fixed at the same site: the sweep called bare `cron list` (which
**hides disabled rows** — `scripts/lib/cron-store.sh:54-64`), and did not check
`hasMore`. It now passes `--all`, and skips the sweep entirely when `hasMore == true`,
because there are no pagination flags and acting on a partial list is not safe.
Under-deleting is.

Note the sweep's premise was doubly wrong: jobs are created `--delete-after-run`, which
fires only on a successful run — so anything the sweep could still see was by
construction *not* successfully completed.

## 5a. The suppressor must be bounded by cron freshness, not mere presence

The reconciler suppresses re-dispatch when a live `qa-autoreview-pr-*` cron row looks
`running` or `queued` (`qar_cron_state` in `lib/qa-reconcile.sh`). The first version of
that check suppressed on bare presence of `runningAtMs`/`nextRunAtMs`, with no regard to
age — and that is a bug that **combines with §5's fix to reintroduce the exact loss this
whole reconciler exists to heal, permanently instead of for an hour.**

Walk the combination end to end: a review cron is queued; the gateway restarts before it
fires; openclaw never re-arms a past-due one-shot; `nextRunAtMs` passes with no
`lastRunAtMs` ever appearing. §5's fix is "never delete a never-run row, at any age" —
correct in isolation, because deleting it is exactly what silently lost reviews before.
But an *unbounded* suppressor reads that same permanently-wedged row as `queued` on
every 15-minute tick, forever: attempts never increment, the cooldown/exhaustion path
never triggers, nothing pages, the merge gate is never driven red. Each fix is
individually correct and necessary; together, with no freshness bound between them, the
silent-loss class this reconciler exists to kill goes silent forever rather than for an
hour. The identical shape applies to `runningAtMs` left behind by a killed run — it
would read `running` forever with no completion and no timeout.

The fix: suppression is bounded by the cron row's **own** timestamp against a staleness
budget, not by mere presence of the field. `qar_cron_state` takes `now_ms` and a budget
(`QA_RECONCILE_CRON_STALE_S`, default `1800`) and returns one of seven states instead of
five — `running`/`running-stale` and `queued`/`queued-stale` split apart, plus the
unchanged `done`/`absent`/`unknown`. Only the fresh states suppress; `running-stale` and
`queued-stale` fall through to the normal candidate path (grace/cooldown/attempts/
global-cap), so a stuck row gets re-dispatched and, on exhaustion, paged and drives the
gate red — exactly like a row that was never created at all.

The `1800` budget is not a second magic number: it is the *same physical fact* §5's
sweep already encodes ("a review cannot still be legitimately in flight after the 1200s
job timeout plus margin") — kept in one place conceptually even though it lives as its
own env-overridable default here rather than being derived from the other script at
runtime (the two scripts don't share process state to derive it from).

Re-dispatching on a stale row is self-healing as a side effect, not just a retry:
`qa-dispatch-pr-review.sh`'s idempotency block deletes any existing job of the same name
before adding the new one, so acting on a stale row also clears the wedged row that was
never going to fire or complete on its own.

The lesson this pins down: **a suppressor and a "never delete" sweep are only safe
together if the suppressor is time-bounded.** Neither change is wrong on its own reading
of its own failure mode — the danger is invisible until you trace what a row that is
simultaneously "never deleted" and "unconditionally suppressing" does on the 100th tick,
not the 1st.

## 6. What was deliberately NOT built: the deploy-side change

The original brief asked for a third change — make `deploy.sh` lane-aware, refusing or
bounded-waiting while any `qa-autoreview-pr-*` one-shot is pending, with a cheaper
interim of snapshot-and-re-arm around the restart. **Neither was taken.** The reasoning:

- A second wait **duplicates a wait that already exists and already gives up**: the
  drain budget is 390s and the fallback is deliberate, observed, and Slack-notified.
- A post-restart `cron add` would execute immediately adjacent to deploy's
  cron-import/restart choreography — the import-clobber trap that auto-rolled back a
  deploy. Ephemeral one-shots are excluded from the durable comparison
  (`scripts/lib/cron-store.sh:47-52`), so it is *probably* safe; "probably safe inside
  deploy.sh's most incident-prone section" is a poor trade for closing a 15-minute
  window.
- The reconciler already heals this loss from GitHub state within one tick, **and**
  heals losses deploy never sees at all: dispatch drops, failed runs, gateway crashes
  outside a deploy. One tested mechanism beats two half-mechanisms.

Cost accepted: up to ~15 min of extra latency on a deploy-killed review, against
incidents previously measured in 18 hours and 15 days. This is a judgement call and is
flagged for Nick rather than settled here.

**Separately worth raising, not fixed here:** openclaw's own drain runs with
`timeout 0ms` on the hard path. Even 60s would have saved the run that died. That is an
openclaw-side setting and deserves its own issue.

## 7. Fail-closed inventory

A gate that skips what it cannot parse *is* the bug. Every unclassifiable input refuses
and pages rather than degrading to "looks fine":

| condition | behavior |
|---|---|
| state file present but unparseable | refuse to re-dispatch this tick + page (a corrupt attempt counter must never become an unbounded dispatch loop) |
| policy or `.identity.bot_logins` unreadable | refuse + page — never guess the login set |
| a repo's PR list unreadable | counted, not silently skipped; pages after N consecutive whole-tick failures (a dead watchdog is the outage class this exists to kill) |
| `cron list` returns `hasMore=true` | does not suppress forever — after 2× grace, act on GitHub state and say the cron set was unknown |
| author has no Slack-UID mapping | normal skip, not a refusal — the dispatch path skips those too |

Bounds against the opposite failure (a false-positive storm on a serialized lane):
≥30 min grace from the last head push, ≥30 min cooldown between attempts, **max 2
attempts** per `(repo, pr, head_sha)`, and a global cap of 3 re-dispatches per tick.
Exhaustion pages `#clio_devops` via `slack_notify_critical`, which supplies real
`<@UID>` mentions — a literal `@name` pings nobody.

## 7a. Verified behavior on node-8

Both directions were rehearsed with `--dry-run` against live GitHub state from node-8,
with the state file pointed at a throwaway path so nothing was dispatched:

| bounds | pre-epoch ignored | would dispatch |
|---|---|---|
| production (14d ceiling, freshly minted epochs) | 168 | **0** |
| deliberately widened (epochs + ceiling both 400d) | 0 | **3** |

The widened run is the one that matters: it proves the detector genuinely finds losses
(`H-DevOps#2342`, `#2173`, `#2169`) and that the storm guard — not a broken read path —
is what suppresses them under production bounds. It also exercised the global per-tick
cap, which stopped at 3 and **logged each deferred PR by name** rather than truncating
silently. `failed_repo_listings=0` across all 17 repos in every run.

First-run behavior was confirmed too: with no state file the reconciler minted 17 repo
epochs, dispatched nothing, and emitted exactly one page and one pre-epoch summary line.

## 7b. The unit file is load-bearing, not boilerplate

`qa-review-reconcile.service` is `Type=oneshot`, and the reconciler writes its durable
state exactly **once**, after all repo loops finish. That makes `TimeoutStartSec` a
correctness setting rather than a tuning knob: node-8's `DefaultTimeoutStartUSec` is
**1min 30s** (confirmed live), and a real `--dry-run` tick against the live org takes
several minutes. Without an explicit timeout, systemd would SIGTERM every tick before it
persisted anything — the attempts counter would stay 0 forever, the cooldown would never
engage, the exhaustion page would never fire, and the first candidates found would be
re-dispatched every 15 minutes indefinitely. Unbounded re-dispatch on a serialized lane,
with the underlying loss still invisible.

It is set to `1800`. Every other long-running oneshot in `install-aux-units.sh` sets this
explicitly (30min, or `infinity`); the new unit was briefly the only outlier, which is
exactly how the defect was found.

## 7c. Known residual limitations

Surfaced by adversarial review and accepted rather than fixed, so they are not
rediscovered as surprises:

- **The per-repo gated-base rule is reimplemented** in `qar_repo_gated_base` rather than
  called, because it lives in YAML (`external-pr-review.yml:161`, `qa-autoreview.yml:135`)
  and is not callable. Every other scope rule is *called*, not copied. This one is a
  two-reader drift surface and is cited per-line in the lib.
- **`.identity.bot_logins` contains `adk47`**, Aaron's human login, so a human review by
  Aaron on the head sha satisfies the bot-review test and suppresses the reconciler for
  that PR. This is pre-existing and deliberate (the policy's own field note explains why
  `adk47` cannot be dropped until no open PR carries an adk47-filed thread), but it is a
  genuine fail-open in *this* consumer and should be revisited when that entry retires.
- **`__ready_cache__` and `__repo_epochs__` are never evicted.** The per-PR prune keeps
  them wholesale, so timeline-cache entries for closed PRs and epochs for de-allowlisted
  repos accumulate for the life of the state file. Slow growth, no correctness impact.
**Enumeration is env-gated, and that replaced an argv flag that was a real hole.** The
first cut exposed `--list` as a flag, reasoning that "exact, sole argument" made it
unambiguous. It does not: `external-pr-review.yml` passes the raw, attacker-influenceable
`client_payload.repo` into this same script as its single argument, and every caller reads
rc 0 as "allowed" — so a payload of literal `--list` produced argv **identical** to a
trusted enumeration call, returned 0, and let the ack step cross its credential gate and
attempt a GitHub API write on an unvalidated repo. Downstream re-validation happened to
contain it, but the predicate's fail-closed contract was broken.

Enumeration now requires `QA_EXTERNAL_REPO_ALLOWLIST_ENUMERATE=1` **and zero arguments**.
A payload is always an argument, so it can never reach the enumeration path even if the
env var were set in the runner; any invocation with an argument is always and only the
fail-closed predicate. The lesson generalises: a capability that must be unreachable from
untrusted input cannot be gated on the *shape* of that input, because the attacker
controls the shape. It has to be gated on a channel the attacker does not control.

## 8. Relationship to the merge gate

`merge_gate_repos` stays **empty** in this change. The field note named two
prerequisites; this work is both of them, and the merge-gate branch is built and
tested now so that flipping the policy later is a data change with no new code:

- on a repo in `.merge_gate_repos`, a stale `pending` also counts as "no verdict"
- **on a gated repo a bot review is NOT sufficient — the status is the gate.** The
  reviewing skill posts its COMMENT review (Step 6) *before* it publishes the terminal
  `qa-review` status (Step 6b). A gateway death in that window leaves a bot review on the
  head sha with the required check still `pending`. Counting the review as a verdict there
  would leave the gate pending forever while the reconciler believed all was well — and
  GitHub never times out a required check that was never reported, so the PR would be
  permanently unmergeable, silently. This script's own failure class, reproduced inside
  its classifier. Gated repos therefore require a terminal status regardless of any
  review; bot-review + pending is a `candidate`, retried and driven red on exhaustion.
  Ungated behavior is unchanged (no required check exists, so the review IS the outcome).
- on exhaustion, the reconciler additionally drives `qa-review` → `failure` via
  `qa-review-status.sh`, whose contract already anticipates "dispatch lost" → failure

Populating `merge_gate_repos` is the actual one-way door (it starts seeding `pending`
on real PRs, and GitHub never times out a required check that was never reported). That
remains a separate, deliberate decision for Nick and Aaron.
