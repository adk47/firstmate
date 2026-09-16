# Working in hydra: the distilled doctrine

This is the long-form, hard-won "how we work in hydra" reference, distilled from
recurring incidents and reviewer corrections. The repo `CLAUDE.md` is the short
authoritative version (verify-before-agreeing, releases, hot-patching skills, codex
auth, the extension decision tree); this file is the detailed companion. Where the
two overlap, CLAUDE.md wins and this doc points to it rather than re-explaining.

Each lesson is the durable mechanism plus the why, not a point-in-time status. Where
a model or version appears, it is a dated example of the principle, never the rule
itself: routing churns, the principle does not.

---

## PR and git workflow

**Never open a PR unless explicitly asked.** Committing and pushing the branch is
part of "implement the plan"; `gh pr create` is not. A PR is outward-facing (it
triggers QA auto-review and notifies reviewers), so it is the human's call. End
implementation at "branch pushed, tests green, ready for a PR." Same caution for other
reviewer-facing actions (requesting reviews, commenting on others' PRs).

**Branch before touching code on `main`, and cut a fresh branch per PR.** Never edit
on `main`; never reuse a just-merged branch for the next piece of work (it re-shows
merged files and muddles the diff). The sequence is `git fetch origin main` then
`git checkout -B <new-branch> origin/main`, then edit. Exception: intentional PR
stacking, where you branch B off A and say so explicitly.

**`git reset --soft origin/main` in a long-lived worktree silently REVERTS whatever
merged since that worktree was created.** `reset --soft` moves HEAD only — it never
refreshes the working tree — so `reset --soft origin/main` followed by `git add -A`
stages the worktree's **stale** copies as a diff against the *new* `main`. The result is
a revert wearing a feature commit's clothes: `git log` and `git show` on the branch tip
read perfectly fine.

2026-09-16, PR #955: a worktree created off `244fb6da` was re-committed this way across
several revisions while three of its own sibling PRs merged. The head it produced would
have set `memory.search.provider` back to `"openai"` on both profiles (re-breaking
retrieval for six agents, #952), undone the retention stderr/SIGPIPE fix (#953), reverted
the edge auth-store version gate and **deleted that gate's 266-line test suite outright**
(#954). CI was fully green on it — every check passed, because the reverted code is
self-consistent.

Two rules come out of it:

- **Read `git diff origin/main...HEAD --stat` before every push.** More files, or
  different files, than the PR owns = **stop**. On #955 it showed 11 files for a 3-file
  PR, which is unmissable once looked at. This is the only cheap tell.
- **Never `reset --soft origin/main` after `main` has moved.** Either
  `git rebase origin/main`, or rebuild: fresh worktree off current `main`, then
  `git checkout <old-branch> -- <only the files the PR owns>`. After a rebuild, *assert*
  the merged fixes are intact — read the values back, grep for the merged guard, confirm
  any deleted test files exist again and run them. An absent merge conflict is not
  evidence of preservation.

`git worktree add origin/main` pins that base forever and does not track later merges,
so prefer a fresh worktree per PR over reusing one across a merge.

**The QA bot's `REBASE WARNING` is a finding, not procedural noise.** It is the check
that caught the above, and it was the only thing that did. Treat it like any other
blocking finding: reproduce it from the diff stat before answering it, and never wave it
through as a stale-base artifact.

**Reply in-thread to every PR review comment, including the automated QA bot's.** A
chat-only summary leaves the review thread looking unaddressed; the in-thread reply
closes the loop visibly for the reviewer and the next reader. Reference the resolving
commit SHA ("Fixed in `<sha>`..."). If you do NOT act on a comment, still reply with
the reasoning (push back with evidence; see Enforcement philosophy). Every comment
gets an answer, agree or not. Use `gh api repos/<owner>/<repo>/pulls/<n>/comments/<id>/replies`.

**When running a ship pipeline, invoke the named bundled skill, not a hand-rolled
equivalent.** Substituting a raw `gh pr checks` poll for the babysit skill silently
drops its guarantees (verify each finding, reply to every comment, guard the green,
never merge). Gotcha: `gh pr checks` exits non-zero while any check is merely PENDING,
not only on failure, so a background poll whose last command is `gh pr checks`
surfaces a false "failed" notification. End such polls with explicit `exit 0` (or
`|| true`) and key the wake condition on the run's `status==completed` or a non-self
review appearing, not on the poll's exit code.

**Renaming a branch that has an open PR: use GitHub's server-side rename, not the
worktree tool.** A local rename that pushes the new name and deletes the old remote
ref will close the open PR (its head branch no longer exists) and it cannot be
reopened. Instead hit the rename API first
(`gh api -X POST /repos/<owner>/<repo>/branches/<old>/rename -f new_name=<new>`),
which atomically renames on the server, updates open PRs, and adds a redirect; then
sync local. The worktree rename helper is safe only when no PR is open.

**Hot-patch the live host first for time-critical prod fixes, then PR the same change
as idempotent catch-up.** When prod is actively bleeding (bad cron, wrong config),
the order is: back up the live file with a timestamp, edit in place atomically,
restart the load-at-boot service, verify the fix is actually in effect, then commit
to a branch and PR. The later deploy is a no-op because both sides already match. Do
this only under urgency or explicit approval, never speculatively, and PR-first
instead for anything irreversible (data deletion, auth, migrations). Gotcha: do not
leave `*.bak-*` files under deploy-synced paths (`workspaces/`, `skills-all/`) or the
deploy pre-flight refuses the next sync as "would delete server state." Put backups
outside the rsync scope, or delete them before the deploy fires. For hot-patching
`skills-all/` specifically, see CLAUDE.md (the announce-before-write contract).

**Run live-runtime checks on the gateway host (node-8), not your laptop.** The local
machine lacks the gateway binary, the live auth stores, the journal, and the real
runtime, so runtime-dependent runs prove nothing and can mislead; node-8 is also where
the self-hosted CI runner executes. Exception: hermetic bats suites that PATH-shadow
the network (`openclaw`/`gh`/`curl`/`journalctl`) run and pass locally, and you should
use them for fast red-green before the PR. Sub-exception to the exception: a "hermetic"
suite still false-fails on macOS if the script-under-test uses GNU-only coreutils
(most often `date -d`), so calendar/epoch math goes to node-8. Anything touching the
live gateway, auth stores, journal, or live config stays on node-8.

**For a shared PR, lead with the concept, then the code.** When the founder shares
work he often wants conceptual and architectural feedback first (is the approach sound,
what is missing) rather than a line-by-line nitpick. Frame review as "here is my take
on the concept plus the implementation details," not a wall of inline change-requests.

---

## Enforcement philosophy

**Instruction-only guardrails are insufficient for autonomous flows; reach for the
mechanical layer.** A "HARD RULE" in a skill's prose is defense-in-depth, not the
answer. (Real incident: an anti-confabulation rule added to a credit-verification
skill was ignored by the very next autonomous batch three minutes later.) When asked
to "enforce X" or "make sure the agent does Y," propose a deterministic layer first:
in rough order, wrap the specific bash helper (the shell boundary sees 100% of
traffic), then a post-hoc audit/redaction hook, then a `before_tool_call` hook ONLY
for tools you have confirmed it actually fires on (it is a silent no-op for autonomous
`exec`). The bash gate cannot be confabulated past.

**Guard an invariant that spans an open-ended SET of files with a drift test, not
vigilance.** When a property must hold across every member of a growing set — "every
restart-capable watchdog must honor the maintenance flag," "every workspace SKILL must
be canonical" — a reviewer eventually misses a new member. Enumerate the set
mechanically and assert the property on each, with an explicit exempt-list for the
conscious exceptions, so adding a member without the property fails CI. (Example:
`scripts/tests/maintenance-guard-drift.bats` globs `scripts/*-watchdog.{sh,py}`,
subtracts `scripts/tests/fixtures/maintenance-guard-exempt.txt`, and fails on any
unguarded remainder — so a future watchdog cannot silently fight a maintenance window.)

**When you cut skill prose to forbid a behavior, grep for every template that
demonstrates it.** Agents pattern-match on concrete examples regardless of surrounding
"do not" prose. (Real incident: a PR marked a feature offline in the top-level prose
but left a code-block template 40 lines down; a run followed the template verbatim and
forged events to bypass the gates.) After deciding "no more X," grep the file for every
script name, event type, command flag, and message template that demonstrates X, and
delete or rewrite each. Default to deletion; rollback prose belongs in git history,
not the live skill. Then dry-run a small batch to confirm the tool-call sequence
matches the new prose.

**A shared skill is edited in `skills-all/<name>/` only; workspace shadows are
forbidden by default.** Workspace copies rank above the canonical at bind time, so a
shadow either silently duplicates canonical (dual-edit burden) or silently freezes
stale doctrine for one agent. CI drift-check blocks new shadows. The only exception is
genuinely per-agent content, which must be declared in the divergence manifest. Full
mechanics live in the CLAUDE.md extension decision tree (rule 6).

**When adding a write surface for a new agent class, place it physically outside
`skills-all/` from day one.** A list-ID guard inside a shared read-only skill is
necessary but not sufficient: extending that skill with write methods silently
propagates the capability into every agent workspace (Caroline, ops, cmo). Put the new
skill in its own tree, wrap a tiny scoped CLI that does a preflight ownership check and
refuses out-of-scope targets, keep credentials only in the dispatcher unit's
environment, and add a CI lint-guard asserting the skill is not referenced by any
gateway config. Push back on any plan that says "extend `skills-all/<x>` with write
tools for the new agent."

**Frame doctrine runtime-agnostically.** Do not tie a rule to a specific model or
runtime name. Routing churns frequently (agents get re-pointed between providers), so
"because this agent runs on <model>" rots the moment routing changes; the underlying
principle (for example, "skill descriptions are always loaded and compete for prompt
budget") is true regardless. State the durable mechanism; name a model only as a dated
example.

**A gate that reads runtime state must be tested against the target profile, not just
fabricated fixtures.** A bats test feeding the gate synthesized session logs proves the
logic, but proves nothing about whether production can ever produce the passing input.
(Real incident: a credit-approve gate passed unit tests fed `browser` tool calls, but
the browser tool is disabled in every profile, so the gate blocked every approval on
its first real run.) Add a precondition that asserts, in the target profile, that the
required tool is present and enabled, and fail loudly at boot, not silently at
gate-time.

**Treat reviewer and user claims as hypotheses to verify, not facts to act on.** This
applies to everyone, including the founder, Clio, and multi-agent review passes; it
goes both ways (false-positive findings, and over-confidence in your own work). Before
acting, open the file, run the command, read the git history, and cite `file:line` or
command output. Push back plainly with evidence when a claim does not match the code;
do not silently capitulate or perform agreement. The same applies to plans: ground
every step in verified artifacts, not speculation. This is the load-bearing rule in
CLAUDE.md.

**Check the dependency for a native config knob before building a custom workaround.**
For symptoms like "X grew unbounded" or "Y needs periodic cleanup," skim the
dependency's docs for `maintenance`/`retention`/`prune`/`ttl`/`gc` sections, grep the
installed dist (defaults often hide a gated-off feature), and search upstream issues by
exact wording. (Real incident: a custom bash-trim plus systemd-timer PR was about to
merge when we found the dependency already shipped a native `session.maintenance` key;
the replacement was a 5-line declarative config.) Five minutes of upstream research
beats maintaining a custom layer forever.

**When triaging an error-rate spike on your own endpoint, grep the User-Agent first;
the source is often your own monitor.** (Real incident: a reported "60% silent user
failure" on a webhook was the health-monitor probing unsigned every five minutes; real
traffic was passing fine, and the proposed step-1 fix would have broken what worked.)
Before quoting a 4xx rate as user impact, bucket distinct User-Agent strings and source
IPs; if the reject path does not log UA, packet-capture for a few minutes. Corollary:
a health probe that sends unsigned bodies and accepts 401 as "OK" is structurally blind
to the exact failure class it should catch; sign every probe and assert 200.

**Inspect a real API response before writing field extractors.** Doc-driven field-name
assumptions silently produce no-op pipelines. (Real incident: extractors written from
docs used `spotifyId`/`isrcs[0]` when the live fields were `spotifyTrackId` and
`metadata.isrc`; jq returned null on real data, env vars stayed empty, and the whole
commit was a no-op until tested live.) Make one real call, dump a representative item,
eyeball the actual names, nesting, and types, note the high-signal fields the docs omit,
then write the extractor and a fixture from the real shape.

---

## Safety and destructive ops

**Never run a `ps`/`pkill` filter against a live box without printing the matches
first.** (Real incident: a broken `--ppid` filter silently fell back to "all PIDs" and
mass-killed caddy, the CI runner, and sshd, dropping the connection mid-script.) Run
the exact filter with `echo` instead of `kill`, visually confirm the count and
identities, then make the destructive call. Prefer `pkill -9 <exact-short-procname>`
(clear semantics, refuses empty patterns) over a synthesized PID list. Recovery note:
systemd survives, so `systemctl --failed` then `systemctl start <svc>` restores killed
services.

**Fail loud on invalid CLI args; never let a typo fall through to a default that does
a real write.** A `${1:-default}` pattern silently accepts garbage (typos, `--help`,
partial edits). (Real incident: a diagnostic `dispatch-cv-batch.sh --help` failed the
integer regex, reset to the default batch size and real-apply mode, and fired 500
admin-API writes with no Slack reply.) Distinguish "missing arg" (safe to default)
from "invalid arg" (must exit non-zero with a usage message); match enums against an
explicit allowlist. Audit every production dispatcher that takes positional args.

**Check for an in-flight long-running op before merging or deploying.** A deploy
restarts the gateway, and any tool execution inside the gateway process tree (a bulk
apply, an agent turn) dies with it; worse, a dispatcher's failure-handler Slack post
can die before it fires, so the failure is silent. (Real incident: a 500-credit bulk
run died mid-apply when a deploy stopped the gateway; hundreds of writes landed in
unknown state with no failure notification.) Before deploying, check the apply log for
an `apply_started` with no matching `apply_finished`; if unmatched, wait or coordinate.

**Agent repo clones under `workspaces/repos/` and `workspaces/*/tmp/` are TTL-swept.**
Both paths are rsync-excluded, so deploys never clean them; by 2026-07 they had
accumulated 90 clones / 26GB of stale pre-fix revisions. `scripts/sweep-workspace-clones.sh`
(wired into the weekly cleanup timer) deletes clones idle past the TTL (repos/ 14d,
tmp/ 7d) ONLY when git-clean, fully pushed, stash-free, and off the keep-list of
canonical long-lived clones; anything dirty/unpushed/odd is held and reported to
#clio_devops, never deleted. Corollary: work you want to survive in a clone must be
pushed — an unpushed branch keeps the clone held forever but is one `rm` away from
gone, and a pushed branch is the only durable copy.

**Cap parallel subagent fan-out; do not spawn one per work item.** For a large batch,
the orchestrator should round-robin tasks through a bounded pool (cap around 10,
configurable), reusing a slot as one returns, rather than fan out hundreds of agents.
The unit of work is per-profile (fresh context), not per-item. This keeps per-item
rigor without the operational cost of unbounded fan-out.

---

## Bash, jq, SQLite, and code traps

**An apostrophe anywhere inside a single-quoted jq filter terminates the bash quote.**
Bash single-quotes have no escape; one `'` (even in a comment like "OpenClaw's shell
tool") ends the literal and turns the rest of the jq script into bash tokens. The error
points at where bash gave up, several lines below the real break, so it is misleading.
Prefer plain English in jq comments ("the OpenClaw shell tool", "do not"), or pass the
filter via a `<<'JQ'` heredoc with a quoted delimiter. Always `bash -n` after editing
any script with embedded jq.

**jq's `//` (default) operator treats boolean `false` as null-equivalent.** `false //
"x"` returns `"x"`; only `null` and `false` are falsy (empty string, `0`, `[]`, `{}`
are not). (Real incident: `.apply.dry_run // "true"` turned an explicit `false` into
`"true"`, so a real-apply run was labeled DRY-RUN.) When a downstream test depends on
the boolean distinction, use `| tostring` and test the literal string, or an explicit
`if/then/else`, never `// <default>`.

**A cron has TWO session shapes with opposite meanings — count the BASE, never the total.**
`agent:<id>:cron:<jobId>` is the persistent base session, one per job. `agent:<id>:cron:<jobId>:run:<runId>`
is a per-run child, and openclaw 2.0's cron reaper deletes those on purpose after
`cron.sessionRetention` (`dist src/cron/session-reaper.ts`, `DEFAULT_RETENTION_MS = 864e5` = 24h).
Counting both together makes any agent whose crons run less often than daily read as having zero
cron sessions. (Real incident, PR #946: I read that combined zero as a false positive and built a
"the reaper explains it" gate that would have permanently suppressed the wedge signature. Measured
base/run on live main the same day: ceo 0/0, cmo 0/0 against clio 2/1, cto 12/0, devops 3/4,
finance 1/1, operations 6/32, qa 522/12, scout 2/1 — base sessions clearly survive the reaper.)
**The base session's lifecycle, since the obvious reading of a zero is wrong twice over:** a RUN
creates it (`dist isolated-agent-*.js` resolves `cron:${input.job.id}` inside the run path), and it
is deleted with its owning job id (`removeCronJobBaseSession`: *"Removes the reusable base session
whose owning isolated cron job was deleted"*). Declaration-keyed crons — every
`skill-collection-review-<agent>`, `heartbeat:<agent>`, `memory-core:*` — are re-registered with a
FRESH uuid on every boot, so after a restart the old base session goes with the old job and the new
job legitimately has none until its first fire. Verified after the 2026-09-16 09:41Z restart: all
nine `skill-collection-review-*` jobs showed `lastRunAtMs` ABSENT with next fires days out, while
repo-declared `support-email-triage-hourly` had a real run and a base session. So **"enabled cron +
zero base keys" is the EXPECTED state for any declaration-keyed cron that has not fired under its
current registration** — a guard must skip those and flag only a job that HAS fired and still has
none. Also note `CronSessionLifecycleClaimError` is
`Session "<key>" changed while starting work. Retry.` with `admissionDisposition:"session-conflict"`
— a retryable RACE, not a missing-session error, so it is not evidence of an absent base session
either. (Beware mixing censuses across a restart: the 75.4h/52.3h `lastRunAtMs` values that made
this look like a long-standing wedge were pre-restart readings of job ids that no longer existed.)

**Python mutation testing: clear `__pycache__` between runs, or a restored file still
executes the MUTATED bytecode.** A test module that loads its subject with
`importlib.util.spec_from_file_location` + `exec_module` can be served stale bytecode left
by an earlier `python3 -m py_compile`, so `cp orig back && rerun` re-runs the mutation.
(Real incident, PR #947: a six-mutation matrix produced two false GREENs and one false RED
-- the restored file was byte-identical to the original by `diff`, yet a test kept failing
on a constant the source no longer contained. `find . -name __pycache__ -exec rm -rf {} +`
before every run fixed it and reversed two of the six verdicts.) Mutation results are only
evidence if the interpreter actually re-read the file: clear the cache, and `grep` that the
mutation landed before trusting either colour.

**Two guards that both exclude the same fixture are each UNTESTED.** If a decoy is rejected
by a type check *and* a name check, mutating either one away leaves the suite green -- the
tests prove only that the pair rejects it, never which one does the work. (Real incident,
PR #947: `context.compiled` decoys were excluded by both `type not in (tool.call,
tool.result)` and `data.name != create_ticket`; removing either guard was invisible, and
dropping the name check would have counted all 2,866 weekly tool.calls as support tickets
instead of the 359 real ones.) Write one fixture per guard that defeats every OTHER guard,
so each guard has a case that fails when it alone is removed.

**jq `any(generator; cond)` rebinds `.` inside a pipe in `cond`.** `any(["bass"][]; .
!= "" and ("pau romero" | contains(.)))` returns true because `contains(.)` sees the
post-pipe value. Bind the iterator first: `any($items[] | . as $x |
<expr-using-$x>)`, or build the boolean array and use the `array | any` form.

**Python: `except urllib.error.URLError` does NOT catch a broken response read.** urllib only
wraps exceptions raised by `h.request()`; failures during `getresponse()` or while reading the
body escape raw — `http.client.RemoteDisconnected` (a `ConnectionResetError`, so `OSError`),
socket timeouts, and `IncompleteRead` (an `http.client.HTTPException`). In a per-item loop over
thousands of rows this is the difference between "one item fails, the run continues" and "the
whole batch dies on a traceback at row 400". Catch `(OSError, ValueError,
http.client.HTTPException)` — `URLError` and the connection errors are all `OSError` subclasses,
`ValueError` covers `json.JSONDecodeError`. Keep any audit-log write OUTSIDE that catch, or a
log failure gets misfiled as a remote failure. `scripts/close-stale-conversations.py` does this;
`scripts/close-resolved-conversations.py:564` still has the narrow two-exception catch.

**Do not instruct an agent to call the Lobster tool directly; wrap it in a shell helper
called via `exec`.** The Lobster tool's gateway schema advertises `flowId` and
`flowExpectedRevision` as optional (the one tool handles both run and resume), so the
agent reliably populates them even when prose says not to, and the run handler rejects
them. This is the canonical case of "prose does not beat schema." Write a tiny bash
dispatcher that curls `POST /tools/invoke` with the correct payload; the `exec` schema
is just `{shell, timeout}`, with no field to hallucinate into.

**A `CHECK` added to an existing `CREATE TABLE IF NOT EXISTS` is a silent no-op on prod
but fires immediately on fresh test DBs.** `IF NOT EXISTS` makes the DDL a no-op on the
live table, so the new constraint never applies there, while a fresh `:memory:` test DB
applies it and fails on fixtures that violate the new rule. (This project hand-rolls
DDL as its migration strategy.) When tightening a schema: audit every raw-SQL `INSERT`
in tests against the new constraint, and add an explicit migration step for prod data
if it must conform.

**`better-sqlite3`'s `db.transaction(fn)()` issues `BEGIN DEFERRED`, not IMMEDIATE.**
Only the `.immediate()` variant write-locks upfront; `.exclusive()` is exclusive. Do
not trust a docstring that claims "BEGIN IMMEDIATE" when reasoning about concurrent
write semantics; verify the call site actually invokes `.immediate()`.

**bats suites must PATH-shadow any CLI with prod side effects.** A test that exercises
a code path calling `openclaw message send` will post to the real prod channel unless a
no-op stub is on PATH. (Real incident: running a lockfile test during review fired nine
alerts into the prod support channel.) Install a default no-op `openclaw` stub in the
shared test setup (and likewise for slack webhooks, `curl`, etc.); do not rely on a
`command -v` fail-open guard, since on the CI/dev/live hosts the binary is present and
the guard passes through to a real send.

**Do not paste literal invisible or control runes into Go source.** Go rejects a
literal U+FEFF anywhere but the first byte (`go vet` flags it), and other invisible
runes are an invisible review hazard. Build them from hex instead:
`string(rune(0x200B))` or bare hex int literals in a map, keeping the source pure
ASCII. Gotcha: the Write/Edit tools encode content as JSON, so a typed `\u` escape
lands in the file as the actual rune; the hex-literal form survives verbatim. Verify
with `LC_ALL=C grep -nP '[^\x00-\x7f]'` plus `go vet`.

---

**`timeout(1)` does NOT unblock a pipe-based capture — orphaned grandchildren hold
the write end.** `out=$({ timeout 60 helper; } | head -c 8K)` still deadlocks when
`helper` spawns its own child (a sleep, a curl): timeout kills the direct child, the
orphan inherits the pipe's write fd, and the reader never sees EOF until the orphan
exits. Found in the DR healer's diagnostics capture (a hanging `--check`'s grandchild
outlived the timeout and held the flock). Fix: capture to a temp FILE
(`timeout 60 helper >"$f" 2>&1 || rc=$?`) — the redirect has no EOF dependency, the
call returns the instant timeout fires, and byte/line caps apply reading the file back.

**Intentional truncation can abort the whole script under `set -euo pipefail`.**
When `... | head -c N` (or `head -40`) closes early, the upstream stage exits on
SIGPIPE (141), the pipeline status goes nonzero, and `set -e`/an ERR trap fires —
mid-decision, exactly when you cut something off on purpose. Nuance: with output
under the ~64KB pipe buffer the upstream stage finishes before `head` exits and no
SIGPIPE occurs, so the bug hides in testing and detonates on oversized payloads.
Append `|| true` to truncation pipelines (preserve the command's own status via a
temp file if you need it), and regression-test with a >64KB fixture.

**`jq --arg` with a large value trips ARG_MAX (`E2BIG`) — use `--rawfile`.** A
128KB `--arg` worked on a dev Mac and failed `Argument list too long` on node-8
(fatter environment eats into the exec arg budget). Any test fixture or script
passing big blobs into jq should write them to a file and use `--rawfile`/`--slurpfile`.

**Secrets must never ride argv: `/proc/<pid>/cmdline` is world-readable.** A
`curl -H "Authorization: Bearer $KEY"` exposes the key to every local user for the
call's duration. Deliver sensitive headers via `curl --config <(printf 'header = …')`
(argv then shows only `--config /dev/fd/N`) or stdin. Same class as the audit rule
for `muso` flags: assume argv is public on the box.

**Predictable root-written paths under /tmp are a symlink-attack surface.** A cron
job running as root that writes `/tmp/<fixed-name>` (locks, cooldowns, logs) lets any
local user pre-create that name as a symlink and make root truncate an arbitrary
file. Keep daemon/watchdog state in a dedicated root-owned 0700 dir under `/var/lib/`
(provision it in `install-aux-units.sh`), and validate before every write: real
directory, `! -L`, owned by the invoking uid (`-O`). Fail closed but keep detection
and paging alive when the dir is unsafe.

## Content and domain rules

**Spotify and Discogs are out for credit verification, as a class.** Not as live
triangulation, lazy cache, background backfill, "optional later unlock," or a schema
stub. The blocker is operational complexity (auth, ToS, scrape fragility, anti-bot),
not just rate limits, so treat the question as closed. MusicBrainz is the only external
Tier-1 source today; if a design genuinely needs a second independent source, it is
something else (self-attestation, ISRC registry, label feeds, human review), never
these two. Scoped to credit verification; other domains may differ. MusicBrainz is OK.

**A profile showing many tracks by other primary artists is not prima facie a
wrong-merge.** Producers, songwriters, mixing and mastering engineers, and arrangers
legitimately appear on records fronted by someone else; that is their work. (Real
incident: a naive "remove tracks where the primary artist is not the profile owner"
heuristic would have deleted 11 of 12 of a beatmaker's real production credits.) Before
flagging mis-attribution, check the profile owner's per-track `credits[]` role; treat a
producer/writer/engineer/arranger role (or the owner's name in the track artists) as
evidence of legitimacy. On vague "remove non-mine tracks" requests for producer
profiles, ask for specific titles instead of bulk-acting.

**Founder-voice rules for any AI-drafted email under the founder's name.** Lowercase
subject line, no exclamation points, no titles in the subject, under 80 chars; body
under 400 chars; one CTA as `[text](url)` with URLs preserved exactly; first names
capitalized; sign off as just the first name alone on its own line (no title, no full
name). No em-dashes anywhere (they read as AI-generated; use commas or periods). Drop
corporate filler ("update your information," "to keep your account active," "let us
know if you have any questions"); be specific about amounts. Keep the warmth phrases
("happens sometimes," "no big deal," "totally fixable, just needs a card swap"): a
customer in a payment-fail state is anxious, and the job is to make it feel routine.

**The dedup flow is fully autonomous for its authorized requesters; do not self-impose
an escalation no rule requires.** When an authorized internal requester triggers a
dedup (merge, then notify, then close ticket) via the ops agent, the whole flow is
pre-authorized by the godmode allowlist and must run to completion without pausing to
ask the founder, even for the customer-facing Intercom notify. (Real incident: an agent
merged profiles correctly, then escalated the notify step; four customers waited hours
for their merge-complete notification.) The "customer-facing writes need founder sign-off"
reflex is explicitly overridden for this flow. The codified text lives in three places
(the ops soul plus two skills); keep them in sync.

**Default operational escalations to the operator who owns the fleet, keep cost-bearing
crons on their flat-rate runtime, and decide-and-execute under time pressure.** Route an
agent's mandatory operational pages (a real `<@...>` mention) to the on-call operator,
not the business-authority founder, while leaving the founder's business-approval refs
untouched. Fix a flaky cron by fixing the actual bug, not by swapping its cost-efficient
flat-rate subscription runtime (as of mid-2026, Codex / gpt-5.5) for a per-token model.
And when the user signals time pressure ("yolo," "I don't have time to think about
this"), offload the decision, not just the work: stop presenting option menus, make the
best reversible call, state the reasoning briefly, and execute end to end.

**Any prose fanned fleet-wide must be em-dash-free.** "Additive in rule-count" is not
the same as "behavior-neutral": injected style can regress. The customer-facing support
agent's founder-voice rules ban the em-dash (U+2014), so a shared doctrine block fanned
into every soul must avoid it (use commas, parentheses, colons, semicolons, or
en-dashes). A CI guard test now fails if U+2014 appears in any soul's doctrine block,
markers included. This same constraint applies to this very document.

---

## Security posture

**The load-bearing anti-prompt-injection control for the customer-facing agent is the
deterministic capability/ownership gate, not an input classifier.** A probabilistic
"ignore previous instructions" detector is strictly weaker than "the write fires only
on a server-verified owner match": detectors that score under 1% error on clean prompts
collapse under adaptive suffixes, and every false positive wrongly blocks a paying
customer (asking to "remove my credits" looks like a jailbreak). The repo's PromptGuard
sidecar is dormant shelfware, wired to nothing, fails open, and cannot see tool-response
payloads. The real control re-verifies ownership server-side against an identity anchor
from a trusted channel (the re-fetched Intercom author email or actor header), never
from chat, bounding blast radius to the requester's own account. Use a classifier only
log-only and fail-open for telemetry; if you want classifier value, implement the
deterministic input-sanitizer steps (strip control/RTL/zero-width chars, length cap) at
the inbound channel boundary.

**Every trusted marker added to an LLM prompt must also be stripped from inbound user
text, stripped from outbound text, and covered by a regression test.** When you wrap
content in a delimiter the model is told to trust (for example `[KNOWLEDGE_BASE]`,
`[CUSTOMER_MESSAGE]`), a customer can paste a forged block and the model treats it as
authoritative, worst of all when the real block is empty that turn. (Real incident: a
RAG hook added a `[KNOWLEDGE_BASE]` injection but forgot the inbound strip entry; review
caught a surviving forged block.) Adding a marker is three changes plus a test, never
just one.

**Some agents have no runtime seam to scan outbound replies; enforce those via doctrine
plus a CI content-guard, not a live scanner.** The customer-facing agent's outbound
sanitizers run inline inside its channel plugin and do not transfer to other agents; the
ops Slack agent binds a built-in plugin with no in-tree code, the one existing
`before_tool_call` hook is a no-op on autonomous `exec` and is bypassed by the CLI post
path, and the proper `message_sending` seam is documented but unimplemented in the
installed SDK. Until that seam exists, the achievable mechanical layer is a regression
test, not a live block. Re-check on dependency bumps; "prose is not enforcement" still
applies, you just enforce it in CI.

**The customer-facing edge agent runs with unrestricted `exec` and no tool deny-list
(latent risk, tracked).** Its soul prose claims "exec denied" and "exactly N tools," but
the runtime imposes no restriction: untrusted customer text could prompt-inject it into
running an admin helper and self-approving a privileged merge. Prose is not enforcement.
The fix is a real `tools.deny` (or an `allowedTools` allowlist) for that agent plus a CI
invariant, not a soul edit.

**Two live production secrets are committed in plaintext (rotation pending).** The
gateway config carries a literal `gateway.auth.token` (the bearer fronting the
code-execution `/tools/invoke` path, so a leak is effectively remote-shell exposure) and
an ElevenLabs API key, both in git history; every other credential uses `{"source":...}`
indirection. Never echo the values into chat, logs, or commits. Caveat learned the hard
way: replacing a literal with a `{"source":"env"}` ref only resolves if the config path
is collector-backed (core targets like `gateway.auth.token`, `plugins.entries.*.config.*`,
or a channel field whose plugin ships a secret-contract); a ref at an unbacked path is
handed to the consumer raw and silently breaks. Verify the target is collector-backed
before assuming a bare ref resolves, and prefer a named env provider with an allowlist
over the wildcard default.
