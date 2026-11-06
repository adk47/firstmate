# hydra — Claude operating notes

## Verify before agreeing — neither I nor Clio is automatically right

When Nick or Clio (or any other reviewer) tells me something about the code,
treat it as a hypothesis to verify, not a fact to act on. Both can be wrong.

- **Verify with evidence before acting.** Open the file, run the command,
  read the diff. Cite file:line, command output, or git history when stating
  a finding.
- **Push back when I disagree.** If something a reviewer says doesn't match
  what I see in the code, say so plainly with the evidence — don't silently
  capitulate, and don't pretend to agree just to move things along.
- **"Clio said X" is not a justification.** Neither is "Nick said X." The
  code, the tests, the runtime behavior, and the git log are the
  authorities.
- **If I'm uncertain, say so.** Better to flag a maybe-wrong claim than to
  rubber-stamp it and ship a regression.

This applies in both directions: when reviewers flag bugs that aren't real,
and when I believe my own work is correct but a reviewer thinks otherwise.
Disagreement is information; suppress it and we both lose signal.

## Where the hard-won knowledge lives

This file is the short, always-loaded doctrine. The detailed, evidence-backed
lessons behind it ship with the repo, so a fresh clone carries the same
hard-won knowledge we built up locally over time:

- **`docs/lessons/`** — the distilled "what bites you and why" reference,
  grouped by surface:
  - `working-in-hydra.md` — how we work here (PR/git workflow, enforcement
    philosophy, safety traps, bash/jq/sqlite pitfalls, content rules,
    security posture).
  - `openclaw-and-codex.md` — gateway, config, skills, cron, plugins, MCP, and
    the Codex/OAuth runtime mechanics. (The four codex failure modes stay
    canonical in this file's "Codex / OAuth auth is centralized" section plus
    `docs/runbooks/RUNBOOK.md`; the lessons file cross-links them and adds the
    rest.)
  - `deploy-ci-pr.md` — why deploys, CI, and PRs go red, and what is real vs noise.
  - `muso-domain.md` — Muso admin API, muso-cli, Trino/analytics, Intercom,
    NocoDB/ClickUp, Slack rendering, and people/roles.
  - `infrastructure-topology.md` — what our infra actually is (entirely OVH;
    AWS decommissioned 2026-05-31), the two frozen `*v3*` stats tables + retired
    Athena vs. the sunsetting V3 pipeline and the live `/api/v3` API, and the "consult H-DevOps
    before touching infra" rule.
- **`.claude/agents/`** — specialist subagents that carry this knowledge and
  cite `docs/lessons/`. See the roster under "Picking the right extension
  mechanism" below. Start with `hydra-operator` for "I am about to do X on
  hydra, what will bite me?"

## Releases

Releases are announced in **#releases** (`C0BSY512MQT`). **Live today: hydra
and web-credits-next.** auth is configured but `enabled=0` until its upstream
posts a rollout status, and mobile is Phase 2 — both are silent on purpose, so
expected silence there is not a watcher failure (details below). Deploy and
release stay decoupled: merging to `main` deploys, and the tag + announcement
is a labeling event after the fact, never a gate.

**Cadence is per-repo**, set by the `cadence` field in
`scripts/lib/release-repos.sh`:
- `per-deploy` — one release per confirmed prod deploy. **web-credits-next**
  (~0.7 deploys/day; each web deploy is already a `release/promote-develop-*`
  train, so a deploy IS a release). **auth** carries the same cadence but is
  `enabled=0`, so it announces nothing yet.
- `daily` — at most ONE release per calendar day (Europe/Rome, from 08:00),
  rolling up everything that shipped since the last cut. **hydra** is `daily`:
  it deploys ~2.7x/day and is internal agent-ops plumbing, so per-deploy posts
  would drown the product releases this channel exists to surface.
  A held tick records **nothing** — that is what makes the roll-up work.

- **Tag format**: `vYYYY.M.D` with no leading zero on month/day
  (e.g. `v2026.5.26`). Several releases can land on one date, so
  `release.sh --auto-suffix` walks to the first free `.N` (`v2026.5.26.1`)
  checking BOTH the local tag and origin.
- **What drives it**: `hydra-release-watch.timer` (every 5 min) runs
  `scripts/release-watch.sh`. Detection is pure gh/git/jq and reads an
  **authoritative per-SHA record**, never an inference:
  - **web-credits-next / auth** — H-DevOps posts a commit status on the app
    repo's own commit (`H-DevOps / deploy` = "Rollout to muso-prod
    (success)"). That names the sha directly.
  - **hydra** — a completed, successful `deploy.yml` run on `main`.
- **Do NOT correlate the `auto: bump muso/<svc> … post-deploy` commit.**
  Earlier revisions did, by timestamp and then by ordinal position, and both
  are unsound: a bump proves a rollout happened but never names a sha, a
  dispatch proves acceptance but not rollout, a failed rollout writes no bump
  at all, and Actions concurrency does not guarantee ordering. The commit
  status is the only signal carrying identity.
- **A repo with no such status cannot be announced**, and is `enabled=0`
  rather than enabled-but-silent. `deploy-auth.yaml` posted none as of
  2026-08-27, so auth is disabled for the same reason mobile is: its
  upstream does not produce the signal. Flip it to `1` when
  https://github.com/Muso-AI/H-DevOps/pull/2799 merges.
- **An unresolved rollout past the grace window fails LOUD, never silently.**
  Every enabled repo is required to have a working status writer, so a
  `pending` that never reaches a terminal state and a record that never
  appears at all are both indeterminate: skipping could drop a real release,
  announcing past it could strand one. Below the window it simply waits.
- **Candidates are drained oldest-first, one per tick**, so two rollouts
  landing between ticks both get announced. A dispatch with no rollout record
  is skipped, not mis-attributed. A **re-run of an old deploy** keeps its
  original `headSha`, so the watcher also refuses any sha that does not
  descend from the last announced one.
- **Highlights come from a tool-less model call, and are never
  load-bearing.** Commit subjects are author-controlled, so they are
  UNTRUSTED input to a language model: the call is direct HTTP with no
  agent, no session and no tools (same posture as `dr-ai-healer.sh`), the
  output is length- and count-bounded, and it is mrkdwn-escaped before it
  reaches Slack. **Never route this through an openclaw agent turn** — that
  runtime has `exec`, which would let a crafted commit subject cause real
  side effects. If the call fails the release is **still announced** with the
  deterministic rendering plus an explicit "highlights unavailable" line.
- **Fails closed on config, best-effort on delivery.** No
  `RELEASES_SLACK_CHANNEL` (from `/etc/hydra/releases.env`) means the
  watcher refuses to run at all — tags cannot be un-cut, so publishing
  releases nobody can see is worse than not running. A Slack failure
  *during* a run is different: the release is already published by then, so
  the post is best-effort and the state file still advances.
- **Per-repo config lives in ONE table**: `scripts/lib/release-repos.sh`
  (display name, emoji, detector, service, rollback link, and a
  `cadence` knob). Adding a repo is a table row.
- **State**: `/var/lib/hydra-release/{repos,announced,highlights}` — under
  `/var/lib`, NOT `/opt/hydra`, which the deploy rsync overwrites.
- **Bootstrap**: a repo that has never been released has no prior tag, and
  `release.sh` refuses to publish full history. Seed a baseline once:
  `./scripts/release-watch.sh --repo=<key> --bootstrap=<ref>`; the next
  prod deploy is then the first announced release.
- **Dry-run**: `./scripts/release-watch.sh --repo=<key> --dry-run` renders
  the exact Block Kit payload to stdout and tags/posts nothing. Human logs
  go to stderr — stdout is the machine channel (`NO_REPLY`, or the payload).
- **Mobile is deliberately silent (Phase 2).** Neither prod lane reaches
  users today: `mobile-ios-native.yaml` stops at TestFlight and
  `mobile-android-native.yaml` uploads to Play track `alpha` as a
  **draft**. Announcing those as "released" would be false. The `ios-app` /
  `android-app` rows are `enabled=0` until H-DevOps ships to production.
- **No CHANGELOG.md**: GitHub releases are the changelog. Don't
  introduce a tracked CHANGELOG file.
- **`hydra-release.timer` is installed but DISABLED.** hydra's daily cut is
  now the watcher's `cadence=daily`, which posts to #releases in the shared
  format instead of #clio_devops. Do not enable the old timer alongside the
  watcher — both would tag the same day.

## Hot-patching skills on node-8

Before editing any file under `/opt/hydra/skills-all/` directly on node-8
(e.g. previewing a fix on the live server before merging the PR), announce
the imminent write so the next deploy doesn't halt at Step 4a:

```bash
sha=$(sha256sum new-content.md | awk '{print $1}')
ANNOUNCE_SHA="$sha" \
  /opt/hydra/scripts/lib/announce-skill-hot-patch.sh nick \
    /opt/hydra/skills-all/<path>
install -m 644 new-content.md /opt/hydra/skills-all/<path>
```

The next deploy's pre-flight drift check accepts the divergence (rsync still
overwrites server bytes with the PR's HEAD bytes — the announce only
suppresses the halt, never the sync). Without an announcement, Step 4a
halts with the existing `DEPLOY BLOCKED — skills-all/ content drift`
runbook (`scripts/sync-from-server.sh skills --apply --only <path>` for a tracked file; a never-tracked file is NOT pulled by it, so `scp` + review + `git add` → commit → re-deploy
or `HYDRA_FORCE=1` after verification).

Ack window is 1h by default (`HYDRA_HOTPATCH_ACK_WINDOW`); stale
announcements stop shielding after that. See `scripts/lib/announce-skill-hot-patch.sh`
and `scripts/lib/acknowledge-hot-patch-drift.sh`.

## Codex / OAuth auth is centralized

Codex (`openai/gpt-5.6-sol`/`-luna` via the codex agentRuntime, ChatGPT OAuth)
credentials live in ONE canonical store. How that store is selected and
refreshed depends on the openclaw version:

- **openclaw >= 2026.8 (current)**: read main's
  `/root/.openclaw-main/state/openclaw.sqlite` ownership row
  `config_machine_state['auth.sharedStore']` first. `location:"state-db"`
  makes that same DB's `authProfiles.store`/`authProfiles.state` rows canonical;
  `location:"legacy-main"` makes
  `agents/main/agent/openclaw-agent.sqlite` (`auth_profile_store` /
  `auth_profile_state`, row `primary`) canonical. Both SQLite modes key OAuth
  profiles as `openai:<email>`; accept only `provider:"openai",type:"oauth"`.
  The runtime refreshes the canonical token in-process. Legacy
  `auth-profiles.json`, `auth-state.json`, and `codex-home/auth.json` are
  archived migration inputs, not recovery or verification surfaces.
- **openclaw 2026.7 (history)**: the canonical source for our tooling was
  `/root/.openclaw-main/agents/main/agent/auth-profiles.json`, written by
  `codex-oauth-refresh.sh`; the runtime itself never reads
  `auth-profiles.json`. It reads (a) the hardcoded inheritance base
  `agents/main/agent/openclaw-agent.sqlite` (`auth_profile_store` row
  `'primary'`, profiles keyed `openai:*`) and (b) each agent's
  `codex-home/auth.json` — the native codex app-server store that actually
  authenticates model calls (`auth_mode:"chatgpt"` + tokens = OAuth via
  `wss://api.openai.com/v1/responses`; `auth_mode:"apikey"` = fleet-wide
  `invalid_api_key`). **`scripts/lib/codex-auth-sync.sh`** fans the canonical
  ACCESS token out to both surfaces and deletes per-agent auth rows; the real
  refresh token exists NOWHERE but canonical (single-refresher invariant).
  `ensure-codex-auth.sh` delegates both modes to it on a 7.x runtime.
- **openclaw <= 2026.6 (history)**: every agent's `auth-profiles.json` +
  `auth-state.json` was a **symlink** to canonical (openclaw resolved the
  symlink before its atomic rename, so links survived refresh).
  `ensure-codex-auth.sh` still implements this when it detects a 6.x runtime.

- **NEVER copy, seed, or fan-out codex credentials (JSON or SQLite rows) into
  per-agent stores.** OpenAI codex uses single-use rotating refresh tokens
  under a per-profile lock (upstream #26322); independent per-agent refreshes
  mutually invalidate the token and kill ALL codex agents at once
  (incident 2026-05-29: 6 agents degraded to Sonnet fallback for hours).
  **On 7.x, `openclaw doctor --fix` DOES exactly this fan-out** (it migrates
  every agent's JSON into that agent's own DB) — never use it for auth
  migration; use `codex-auth-sync.sh`.
- **Detect (current)**: `scripts/lib/ensure-codex-auth.sh --check` delegates to
  the read-only `codex-auth-invariants.sh` on 2026.8 and verifies the selected
  SQLite ownership/store shape. A confirmed violation needs targeted repair or
  re-auth; there is no JSON fan-out to converge. On 2026.7, the same command
  delegates to `codex-auth-sync.sh`, and `ensure-codex-auth.sh` is the
  remediation. The codex-health watchdog independently alerts on
  `authentication token has been invalidated`.
- **Re-auth GOTCHA (pre-2026.8 history)**: `openclaw models auth login --provider openai-codex`
  with no `--agent` writes to the CONFIGURED-default agent (`clio`), NOT
  `main`. Re-auth MUST land in the canonical `main` store — pass
  `--agent main`. On 7.x, follow ANY re-auth with `codex-auth-sync.sh` (the
  login wrote a store the runtime reads, but canonical + the other derived
  stores must be reconverged). **All THREE accounts** (`aaron@muso.ai`,
  `aarondkaufman@gmail.com`, `aaronkaufman@me.com`) must be logged in — a
  third was linked as of 2026-07-28. On current 2026.8, verify with
  `openclaw --profile main models auth list` (expect three `openai:<email>`
  OAuth profiles) plus `codex-auth-invariants.sh --check`; inspect the SQLite
  cell selected by `auth.sharedStore` only when diagnosing a failed invariant.

This generalizes PR #376 (edge/Caroline symlink self-heal + fail-loud
codex-health watchdog) to the whole fleet. Prose alone is not enforcement —
the script and watchdog are. See RUNBOOK §Troubleshooting → "Codex auth
invalidated / silent fallback" for the recovery sequence, and
docs/runbooks/UPGRADE-2026.7.1.md for the 7.1 auth architecture.

**Sharing the store is necessary but NOT sufficient — also converge the refresh
LOCK.** The single canonical store shares the token across the `main` and `edge`
gateway PROCESSES, but does not coordinate the two writers. openclaw serializes
codex refresh with an O_EXCL lock under `<stateDir>/locks/oauth-refresh/`, and
each process derives that path from its own `--profile` state dir, so main's and
edge's locks never collide — at the 5-min pre-expiry margin both processes can
refresh at once, one rotates the single-use token and the loser POSTs the spent
one → `refresh_token_reused`, killing the whole fleet (incident 2026-06-08;
upstream openclaw#3611, Closed with no fix). Fix = converge both processes'
`locks/oauth-refresh/` onto main's via symlink so openclaw's lock excludes
ACROSS processes. **Detect**: `scripts/lib/ensure-codex-refresh-lock-shared.sh
--check`. **Remediate**: same script with no args (also wired into ExecStartPre
via `openclaw-pre-start-heal.sh`). The watchdog pages on the
`refresh_token_reused`/`auth_permanent` signature (main+edge) and on lost
convergence. This is a DIFFERENT failure from fan-out: when it fires,
`ensure-codex-auth.sh --check` is **clean**. The fix depends on openclaw
realpath-resolving the lock dir at acquire time — **re-verify on every openclaw
bump**. See RUNBOOK §Troubleshooting → "Codex Refresh-Token Race".

**The codex PLUGIN is pinned in LOCKSTEP with the runtime — never float it.**
`@openclaw/codex` is pinned to `2026.8.35` on a runtime >= 2026.8.35 (a ladder keyed on the
running core; the values + rationale live ONCE in `scripts/lib/codex-version.sh`). History: 2026-06-16 → 2026-07-14 it was
deliberately held BELOW the runtime at 2026.5.27 because codex@2026.6.x's
"OpenAI route unification" (#90925/#90448) regressed `openai/gpt-5.5` onto the
api-key route; hydra is OAuth-only, so the fleet 401'd `invalid_api_key` and
dropped to `openrouter/gpt-5.4-mini` (incident 2026-06-19, a manual `plugins
install --force` float). RESOLVED on 2026.7.1 (staging-validated 2026-07-14):
codex@7.1 serves gpt-5.5 via OAuth — PROVIDED each agent's
`codex-home/auth.json` is chatgpt-mode (enforced by `codex-auth-sync.sh`; an
apikey-mode file reproduces the 401s exactly). **The URL tell CHANGED in 7.x**:
both auth modes hit `api.openai.com/v1/responses` — OAuth uses the WebSocket
(`wss://`) transport, api-key uses HTTP; `chatgpt.com/backend-api/…` is gone.
**NEVER `plugins install`/`update` codex off the pin**; to move it, bump
`codex-version.sh` (note: the 7.x first-boot doctor auto-floats a stale codex
to the runtime version — with a lockstep pin that is convergent, but it means
an off-lockstep pin would fight the doctor). **Detect**:
`scripts/lib/ensure-codex-version-pinned.sh --check`. **Remediate/self-heal**:
same script no args (wired into ExecStartPre via `openclaw-pre-start-heal.sh`).
The watchdog pages on the `invalid_api_key` signature (main+edge), on the
`authentication token is expired` OAuth-lapse signature, and on version drift.
**Re-verify codex still serves gpt-5.6 on EVERY openclaw bump.** See RUNBOOK
§Troubleshooting → "Codex Plugin Floated Off Pin".

**The token LAPSE was a FOURTH, distinct failure on 6.x/7.x — a consequence of
keeping the bundled `openai` plugin disabled.** In that historical topology,
`authentication token is expired` (`auth error code: token_expired`, all three
guards clean, `refresh_token_reused`/`invalid_api_key` = 0) meant a pure OAuth
credential lapse. Recovery used `codex-oauth-refresh.sh` to rotate the JSON
canonical, `codex-auth-sync.sh` to fan out the new access token, and a restart;
the twice-weekly `codex-token-refresh.timer` prevented recurrence.

**On current 2026.8, the runtime is the sole in-process refresher and that timer
must remain disabled.** A token-expired incident is diagnosed against the
SQLite cell selected by `auth.sharedStore`: run
`scripts/lib/ensure-codex-auth.sh --check`, then
`openclaw --profile main models auth list`. If native refresh reports the
session ended, re-auth through the runtime-owned main store with
`openclaw --profile main models auth login --provider openai --device-code`,
then re-run both checks and `codex-edge-mirror.sh --check`. Do not use
`codex-oauth-refresh.sh`, `codex-auth-sync.sh`, or archived JSON as the normal
2026.8 recovery path; those are pre-2026.8/rollback tools.

**The usage CAP is a FIFTH failure mode — quota, not auth, and the fix is switching
ACCOUNTS, not tokens.** `You've reached your Codex subscription usage limit` fallback
notices with all guards CLEAN and zero 401s = the active subscription's quota is spent.
sol/luna are model variants on ONE subscription, so the model fallback chain cannot
express "try the other account" (2026-07-21: fleet rode paid OpenRouter for hours while
the fresh standby idled). WHICH account is active is the deploy-proof state file
`/var/lib/hydra/codex-active-account` (resolver `scripts/lib/codex-active-account.sh`;
precedence env `CODEX_AUTH_PRIMARY` > state file > baked aaron@muso.ai — `codex-auth-sync.sh`
re-resolves it on every heal, so a switch survives deploys/heals). **Actuator**:
`scripts/lib/codex-account-rotate.sh --auto|--to <email>` (state → sync → drain-restart →
page; 120-min cooldown bounds cap-flap). Auto-trigger: `codex-keepalive.sh` on the cap
journal signature; both-accounts-capped degrades honestly to the OpenRouter rung. See
RUNBOOK §Troubleshooting → "Codex Usage Cap / Account Rotation".

**TWO systems rotate codex accounts, on DIFFERENT surfaces, and they do not know about
each other.** (a) *ours*: the state file above → `codex-auth-sync.sh` → every agent's
`codex-home/auth.json` → the **codex agentRuntime** path. (b) *openclaw's*:
`auth.order.openai` → the runtime `auth_profile_store` → the **`[agent/embedded]`** openai
provider, which runs its own `decision=rotate_profile reason=rate_limit` failover. Nothing
rewrites `auth.order`, and openclaw's per-profile rate-limit cooldown is only
**30s → 60s → 300s capped**, after which `clearExpiredCooldowns` returns the profile to the
FRONT of the order. So an exhausted `auth.order[0]` is retried **roughly every 75 seconds,
forever** — 2026-08-06: aaron@muso.ai at 100% produced **143 cap lines in 3h**, and
`codex-keepalive.sh` read that signature as "our active account is spent", rotated the
state file (a different surface — it changed nothing), burned the rotate cooldown, and
paged ":no_entry: no rotation target left — every alternate account is known-capped" while
gmail sat at 4% and me.com at 0%. **The cap signature alone is NOT evidence about the
account we run.** The keepalive now checks the active account's MEASURED quota first and
says so when the signature is somebody else's. Keep `auth.order.openai` ordered
least-loaded-first; `codex-quota-refresh.sh` pages when its head is measured-capped
(detect-only — rewriting `openclaw-*.json` out of band trips the write-audit watcher and is
reverted by the next rsync, so re-ordering is a PR).

**Per-account quota is MEASURED now, never inferred — and "we could not measure it" is a
THIRD state, not a synonym for healthy.** Rollouts carry no account identity on 7.x, so the
old code archived the fleet-freshest snapshot under whichever account was rotating out. It
was provably wrong: on 2026-08-06 two archives shared a reset epoch **to the second** from
snapshots 2h15m apart (weekly resets are per-account anchored, so that is impossible), and
a 13-day-old row for me.com whose reset had already LAPSED was read as "not capped" ⇒
"healthy" ⇒ the fleet was rotated onto it and capped again within hours. **Measure with
`scripts/lib/codex-quota-probe.sh`** — it runs the vendored `codex app-server` against a
throwaway `CODEX_HOME` and calls JSON-RPC **`account/rateLimits/read`** (that exact name;
the bare `account/rateLimits` is rejected — re-verify on every codex bump). Collector:
`scripts/codex-quota-refresh.sh` (cron `*/20`, measures only, **can never rotate** — the
keepalive stays the sole rotate trigger). **The probe never holds a refresh token**: it
writes the same `SYNC-MANAGED-NO-REFRESH-TOKEN` sentinel `codex-auth-sync.sh` uses, skips
any account expiring within 60min, runs on tmpfs, and asserts the credential was not
rewritten before shredding — so it cannot violate the single-refresher invariant. If that
assertion ever fires (rc 9) the collector **auto-writes `/etc/hydra/codex-quota-probe.disabled`**
and pages; quota then reads UNKNOWN fleet-wide until a human understands why the credential
moved and removes the file. The probe's cleanup trap is armed INSIDE the probe subshell, not
just at file scope — both callers invoke it via command substitution, and a file-scope-only
trap left a cleartext access token in `/run/hydra` on any signalled run.
`cq_row_state` returns **capped | healthy | unknown**; rotate exits **7 = measured capped**
vs **8 = quota unknown** (`--allow-unmeasured` is the emergency override, and its page says
the target was unverified). **Never render a quota number outside `cq_format_evidence`** —
it cannot print a percentage without its age and source, which is the mechanical form of
"never assert a fact the system did not measure".

**Session REVOCATION is a SIXTH failure mode — upstream kills the session, and every
structural guard stays CLEAN.** `token_invalidated` / "Your access token could not be
refreshed. Please log out and sign in again." with `refresh_token_reused` = 0 means OpenAI
ended the OAuth session for that account (a sign-in elsewhere, password change, admin
action). The access token is well-formed and unexpired, the refresh chain is dead too
(`codex-oauth-refresh.sh` answers `refresh_token_invalidated`, "Your session has ended"),
and **all three `ensure-*` guards read CLEAN for the entire outage** — nothing is
structurally wrong, the credential is simply revoked. 2026-07-27: the fleet rode openrouter
~2h. On current 2026.8, recovery needs the runtime-owned `openai` device login
described above; it writes the SQLite store selected by `auth.sharedStore`.
`scripts/lib/codex-reauth.sh` and the `openai-codex` login/provider namespace are
pre-2026.8 recovery paths only. A raw curl to `auth.openai.com/oauth/device/code`
is Cloudflare-blocked (403).

**Codex profile IDs are versioned — do not apply the 7.x namespace split to 2026.8.**
On current 2026.8, the canonical SQLite store selected by `auth.sharedStore` and
`auth.order.openai` both use **`openai:<email>`**. On 2026.7, IDs lived in THREE
namespaces: (1) canonical `auth-profiles.json` used
**`openai-codex:<email>`** — `codex-auth-sync.sh` selected on that prefix; (2) the
derived runtime store (`auth_profile_store` SQLite) and (3) `auth.order.openai` in
`openclaw-*.json` used **`openai:<email>`**. openclaw
resolves auth.order ids with an EXACT key lookup (`store.profiles[profileId]`) — only the
provider KEY is normalized, never the id — so an `openai-codex:` entry in auth.order
resolves to NOTHING and the fallback list is silently empty. That is why nothing failed over
on 2026-07-27. Conversely, an `openai:`-keyed profile in *canonical* is invisible to
`codex-auth-sync.sh` (this swallowed a valid recovery credential for 23min the same day).
Verify current live IDs with `openclaw --profile main models auth list` and
`codex-auth-invariants.sh --check`; config namespace is gated in CI by
`scripts/validate-shared-config.sh`.

**DR layer 2 — when the code-level healers themselves fail, an AI healer escalates.**
`scripts/dr-ai-healer.sh` ("AI-decides, code-executes"): the watchdog fires it when a
CRITICAL signature persists 3 ticks (or immediately on restart-FAILED / crash-loop).
It calls OpenRouter **directly via curl** (default `openai/gpt-5.6-luna`) — the api-key
route is the one model path that survives codex OAuth death, and a raw curl has zero
dependency on the openclaw install. The model only *selects* from a closed allowlist
(the ensure-*/refresh healers + gateway restart); its output is never executed, and
unknown/low-confidence/unparseable answers collapse to a page-only `no_action`. Kill
switch: `/etc/hydra/dr-ai-healer.disabled`. All outcomes page #clio_devops with real
`<@UID>` mentions (`slack_notify_critical` in `lib/slack-notify.sh` — a literal
`@name` pings nobody). See RUNBOOK §Troubleshooting → "AI Healer (DR Layer 2)" for
operations and `docs/lessons/disaster-recovery.md` for the design rationale.

**Upgrade doctrine (rewritten 2026-07-14 for the 2026.7.1 bump; supersedes the 2026-06-29
deferred-upgrade tripwire).** The old hold at 6.1+5.27 ended when staging validation
(docs/runbooks/UPGRADE-2026.7.1.md) resolved its gates: #90925's fix ships in 7.1 (Gate 1,
verified end-to-end — but only with chatgpt-mode `codex-home/auth.json`); the auth→SQLite
migration's threat to credential sharing (Gate 2, #90575 still OPEN upstream) is answered by
our own `codex-auth-sync.sh` architecture instead of a native store. Standing rules for EVERY
future bump:
- **Validate on an isolated staging copy first** — install to a private prefix + state-dir
  copy, never `npm install -g` for a trial. Follow the staging-copy neutering checklist (a
  staging gateway reaches prod via symlinks, absolute paths in the state SQLite, host secrets
  files, and session restart-recovery — all observed 2026-07-14).
- **Re-verify per bump**: codex serves the fleet primary (gpt-5.6 sol/luna) via OAuth; the profile-blind `resolveStateDir`
  workarounds (state-dir env pin, refresh-lock convergence); `codex-auth-sync.sh --check`
  clean; `dist/plugin-sdk/cron-store-runtime.js` still exists; plugin lockfiles rebuilt
  against the new SDK.
- **State migrations are one-way** — cold state archive (gateways stopped) before any bump;
  the JSON is not a rollback path since 6.x.
- **Lane-wedge gate still stands (#97538/#92270)**: fix PR #90308 remained unmerged as of
  2026-07-14, so 7.1 does NOT fix the edge lane wedge — our mitigations (dispatch timeout +
  stuck-lane watchdog, PR #616; per-conv dispatch coalescing, PR #668) stay load-bearing.
  Re-check #90308 on every bump; a release containing it lets us consider retiring the
  coalescing layer.

**2026.8.1 ("OpenClaw 2.0") addendum — researched 2026-08-31, upgrade planned, prod
window gated on the first correction release (see docs/runbooks/UPGRADE-2026.8.1.md
for the full runbook, staging gates A–M, and target architecture).** What changes:
- **The doctor-for-auth prohibition is REVISED for this one migration.** 2.0's
  `doctor --fix` imports auth into the inheritance-base store that secondary agents
  read through (no per-agent fan-out — the 2026-05-29 storm mechanism is gone), and
  it is the ONLY sanctioned auth+session JSON→SQLite migration path. It runs ONCE
  per state dir during the window, after the sentinel scrub (runbook Phase 2), and
  never routinely. Config shape stays PR-owned; doctor migrates state only.
- **Native in-process auto-refresh replaces `codex-token-refresh.timer`** at the
  window (disabled permanently BEFORE first 2.0 boot — two refreshers on a
  single-use rotating token is the refresh_token_reused race, self-inflicted).
- **#90308 re-check result**: auto-closed UNMERGED 2026-07-29 (stale-bot). #97538
  closed "already-fixed"; 2026.8.1 ships adjacent fixes (#104256 reply-lane release
  after hung plugin work; prompt-lock/terminal-cleanup serialization) but canonical
  #85532 stays open — the coalescing layer and stuck-lane watchdog remain
  load-bearing until staging Gate L plus quiet prod evidence say otherwise.
- `agents.defaults.imageModel.primary: "codex/gpt-5.6-sol"` is the ONE surviving
  valid `codex/*` ref in 2.0 (bounded codex app-server image turns) — do not
  "migrate" it to `openai/*`.

**On 2026.8.x edge's auth cell is a MIRROR of main's, never a login (added
2026-09-11).** Each PROFILE reads its own `<stateDir>/state/openclaw.sqlite` →
`config_machine_state` row `authProfiles.store` (column `value_json`, profiles
keyed `openai:<email>`). Doctor populated main's cell at the 2026-09-10 cutover;
edge's was scrubbed on purpose and came up with NO row, so every Caroline turn
fell back to paid OpenRouter (`Explicit auth order for openai has no usable
profiles`) for ~27h. `scripts/lib/codex-edge-mirror.sh` copies main's per-account
ACCESS credentials (access + accountId + expires + plan + email + idToken) into
edge's cell with the `SYNC-MANAGED-NO-REFRESH-TOKEN` sentinel in the refresh
slot — the real refresh token is copied NOWHERE (single-refresher invariant; it
re-reads the target after every write and fails loud on a leak). `access` and
`accountId` are always written together in one transaction: the runtime decodes
the account id from the token and THROWS on a mismatch. It runs from
`openclaw-pre-start-heal.sh edge` (ExecStartPre — so the edge restart the
canonical refresher performs loads the freshly rotated token) and from
`codex-edge-mirror.timer` (daily 04:30 UTC, restarts edge only if the cell
changed). **Detect**: `codex-edge-mirror.sh --check`; **dry-run**: `--dry-run`.
The runbook's "Option B" (three device logins on edge) is RETIRED: it would have
created a second refresh chain per account, the exact fan-out topology above.

## One model chain on every user path

Every model call that can decide something about a user goes through
`scripts/lib/model_chain.py` (docs/model-chain.md). Captain 2026-11-03:
"primary = the OpenClaw subscription token model; when it runs out, OpenRouter
deepseek 1017."

- **tier 1** `openai/gpt-6-sol` via `scripts/lib/codex-judge-exec.sh` — tool-less,
  sandboxed, $0. **tier 2** `openrouter/deepseek/deepseek-v4.1-flash-1017`.
- **Adding a rung, or any different fallback model, is a SPEND decision.**
  `validate-config-matrix.sh` check 6b pins every agent and cron fallback list to
  exactly one DeepSeek entry; a PR that changes it argues the money. (The old
  luna/haiku hops are gone: they were paid FRONTIER models, so a subscription
  outage silently upgraded every agent turn onto frontier inference.)
- **A tier that cannot serve SKIPS with a reason, never answers blind** — e.g.
  no headless web search on codex-cli 0.156.1 (`reason=web_search_unavailable`).
- **`unsafe` ABORTS the chain**: a tool or safety violation is never laundered
  onto a metered model.
- **Strict structured output**: codex rejects a schema without
  `additionalProperties: false` (`400 invalid_json_schema`). `strict_schema()`
  normalizes it for every caller — a live call, not a fake, caught that.
- **Read it with** `python3 scripts/model-chain-watchdog.py --canary` (>20%
  tier-2 share in the window, or any exhausted chain, pages #clio_devops; the
  timer runs `--alert` every 15 min).
- **The chain is a CLIENT.** It approves nothing: every caller keeps its own
  caps (`CappedJudge` $25/day + per-run, doc-verify $5/day), gates and
  fail-closed path, and an exhausted chain makes the caller DEFER/HOLD.
- **Every metered call carries the ONE ZDR block** (captain 2026-11-04: "we need
  [ZDR] ... only use the fastest cheapest ZDR deepseek models ... protect our
  code"). `model_chain.ZDR_ROUTING` = `zdr: true`, `data_collection: deny`,
  `sort: price`, `quantizations: [fp8, bf16, fp16]`, `max_price 0.30/1.20`,
  `ignore: [Google]`; `validate_routing()` REFUSES anything weaker (no zdr flag,
  int4/int8/fp4/unknown, uncapped price) and `call_deepseek` sends it on every
  call — `sensitive=False` cannot opt out. The config half is
  `scripts/check-zdr-routing.py` (validate-config-matrix check 10): every
  `openrouter/deepseek|z-ai` ref in the OpenClaw configs needs
  `compat.openRouterRouting` passing the same guard. Measured 2026-11-04: the
  block lands on Morph fp8 at $0.032/$0.50 per M (8/8), the same model without
  it lands on InferenceNet at $0.08/$0.55. **Fireworks is retired from
  production paths** (6.5x–9.4x the price, account-wide ZDR is an
  Enterprise-only toggle we cannot verify); its egress rule is gone and
  `check-zdr-routing.py` fails on any surviving `fireworks/` ref. Claude stays
  on CLIProxyAPI, never Bedrock. Inventory + retention evidence:
  `data/zdr-prod-callers-z1/report.md`.

## Session budgets must exceed each agent's PROTECTED footprint, or crons wedge

`session.maintenance` has two caps, and BOTH silently kill cron surfaces when an
agent outgrows them: `maxEntries` (index entries) and `maxDiskBytes` (sessions-dir
bytes, enforced PER AGENT). In openclaw 7.1 the reapers protect `:slack:` keys and
treat `:cron:` keys as disposable, so once an agent's protected footprint crosses a
cap, every sweep deletes ALL that agent's cron session entries and every fire dies at
setup with `CronSessionLifecycleClaimError` — restart-immune, no self-heal.
This has now happened three times: `maxEntries` on 2026-07-16 (PR #694, 100 → 1000);
`maxDiskBytes` on 2026-07-27, when `operations` crossed 512mb and ALL 8 of its
enabled crons died for ~25h; and `maxEntries` AGAIN on 2026-08-14 (issue #829),
when `scout`'s 1,145 protected Slack threads crossed 1000 while it sat at 17.6%
of its disk budget — the guard fired but named the wrong cap. Caps are now
`maxEntries` 10000 and `maxDiskBytes`/`highWaterBytes` 8gb/6gb.

**openclaw never auto-prunes protected Slack threads, so the protected footprint
grows without bound — every fixed cap is a future outage with a date on it.**
Raising a cap buys time, it is not a fix.

- **Bound:** `hydra-session-thread-retention@{main,edge}.timer` runs every 6h. It selects only
  terminal Slack channel thread sessions inactive for 14d, then deletes them
  through the gateway's `sessions.delete` lifecycle API with session-id + updatedAt
  compare guards and the Hydra `requireInactive` runtime backport. The gateway
  archives transcripts but never interrupts active work; the exact key matcher
  excludes channel roots, DMs, synthetic sessions, and all
  `:cron:` keys. Dry-run manually with
  `scripts/prune-completed-slack-thread-sessions.sh --profile main`.
- **Detect:** `scripts/lib/ensure-session-budget-headroom.sh --check` (0 clean / 1
  violation / 2 read error). Wired into `openclaw-pre-start-heal.sh` (report-only,
  never blocks start) and `cron-health-watchdog.sh` (pages #clio_devops, 6h-deduped).
  DETECT-AND-PAGE ONLY on purpose — re-sizing is a human decision, and auto-raising
  would defer the same outage with nobody informed.
- **Fast manual census:** an agent with enabled crons and ZERO `:cron:` keys in
  `agents/<id>/sessions/sessions.json` is wedged right now.
- **`config set` is NOT enough — restart the gateway.** The CLI says "No gateway
  restart needed" (true for the file), but the running daemon caches the budget and
  keeps enforcing the old one. Verify with `grep -c "disk budget still above"` on the
  post-restart journal (expect 0).
- Full evidence chain + the `sessions cleanup --dry-run --json` signature is in
  `docs/lessons/openclaw-and-codex.md` under "Cron".

## Each gateway MUST pin `OPENCLAW_STATE_DIR` to its own profile

Every gateway's systemd env file pins its profile state dir — `/etc/openclaw/main.env`
carries `OPENCLAW_STATE_DIR=/root/.openclaw-main`, `edge.env` carries
`=/root/.openclaw-edge`. **Never put it in `shared.env`** (both gateways load shared →
one value would force them onto the same state dir). Without the pin, the daemon's
model-invocable **managed-skills** tier silently goes stale, fleet-wide.

Why (root-caused 2026-06-29): openclaw has TWO state-dir resolvers. `resolveGatewayStateDir`
is profile-aware (config/agents/cron/sessions → `-main`), but the **managed-skills** tier
(plus the OAuth dir and the codex refresh-lock) uses the profile-**blind**
`resolveStateDir(process.env)` — which checks `OPENCLAW_STATE_DIR`, else falls back to the
existing legacy `/root/.openclaw`. `--profile main` sets `OPENCLAW_PROFILE` only at *runtime*
(a JS setenv), so it never reaches the daemon's `process.env` for the skill loader. Result:
with the var unset, the daemon injects the **frozen `/root/.openclaw/skills` catalog**
(last written pre-#336, ~2026-05-26) into **every** agent — so any skill added since then
(`muso-streams-lookup`, `billion-streams-club`, the entire **ship-kit**, `muso-cli`,
`muso-read`, …) is **absent from agents' invokable catalog**, even
though it's deployed to `-main/skills` and shows "ready" in `openclaw --profile main skills
list` (the CLI gets `--profile`; the long-running daemon does not — that mismatch hid the
bug for a month, and is why the `muso-streams-lookup` skill (#592) + CMO anti-confab doctrine
(#597) changed nothing: CMO never had the skill to invoke).

- **Detect / enforce:** `scripts/deploy.sh` fails loud if a per-profile env file is missing
  the pin (or if `shared.env` has it), and after each restart asserts the running daemon's
  `/proc/<pid>/environ` actually carries it (env-file vars show in `/proc/<pid>/environ`;
  the runtime-set `OPENCLAW_PROFILE` does NOT — so `/proc` is the reliable post-restart gate).
- **DO NOT** `rm /root/.openclaw` — a nonexistent `~/.openclaw` makes `resolveStateDir` fall
  to an empty dir = the pre-#336 outage (agents lose ALL managed skills). The legacy dir is
  runtime-dead but must keep existing; the pin (not deletion) is the fix.
- This is a hydra workaround for an upstream openclaw defect (daemon managed-skill loader /
  refresh-lock use the profile-blind resolver under `--profile`). Re-verify on every openclaw
  bump. The repo already used this lever for cron (`deploy.sh` cron-store import).

## PR CI runs in the cluster, not on node-8

Since 2026-10-27 the repo-only PR Validation jobs run on `runs-on: ovh-hydra` (an in-cluster
ARC pod: non-root `runner`, 2 CPU / 2Gi, no node-8 files or secrets). Only the deploy, the
deploy pre-flight, the QA hand-off and the dispatch workflows stay on node-8 (header of
`.github/workflows/pr-validate.yml`). A new CI tool goes in `scripts/ci/arc-toolchain.sh`;
a test that truly needs node-8's host (real systemd, live `/opt/hydra`) is tagged
`# bats test_tags=host-systemd` or belongs in a node-8 job, never silently skipped.

**Read a red PR Validation from the failing JOB, never the run conclusion.** The
2026-11-03 report "0 of 11 PR Validation runs passed since 20:00Z, hydra CI is BROKEN"
was wrong: `concurrency: group: pr-validate-${{ github.ref }}` + `cancel-in-progress:
true` marks every superseded push `cancelled`, so a burst of pushes looks like a total
outage while the queue simply restarts from the back — 13 of 13 runs in that window
were CANCELLED, not failed, and `main` was green. Before believing a failure is
content, confirm the PR touches the failing file (`gh-axi run view <run> --job <id>
--log-failed`). Two real non-content causes already found: a test reading the wrong
run's output dir (#1721), and `gh` exiting non-zero when it cannot READ a response it
already wrote (`scripts/qa-handoff-publish.sh`, which used to report a landed POST as
"this head now has NO hand-off"). Timing-bound suites also miss deadlines on a 2-CPU
pod; fix the shard/`--jobs` budget, not the assertion.

## node-8 `/dev/*`: never a destructive target

- **NEVER make a `/dev/*` path the target of `rm`, `mv`, `cp`, `install`, `sed -i`
  or `rsync` on node-8.** On 2026-10-09 a `rm -rf /dev/null 2>/dev/null` in an
  ad-hoc SSH one-liner replaced the device with a regular root-owned file; the
  next root redirect recreated it as a plain file and PR Validation went red for
  hours looking like 5 random bats failures. Appending `2>/dev/null` to a
  destructive command does not make it safe — it performs the damage and
  suppresses the one line that would have reported it.
  `scripts/assert-host-devnull.sh` now fails every PR Validation job loudly when
  this recurs, and the watchdog pages (it never repairs; restore needs Nick).

## Credit approvals: nothing approves without a recorded captain decision

Any automation that can APPROVE a Muso credit request is listed in
`policies/credit-approval-automation.json`. CI (`scripts/check-credit-approval-automation.sh`)
fails if a cron runs one unregistered, or enabled without `approved: true` +
`approved_by` + `approval_ref`. The Lobster batch also re-checks that flag at
dispatch and at the write boundary. Why: from 05-18 to 10-11 the batch approved
validator-DECLINED credits through an inverted rule (`approve_owning_track == 100`
means the shortcut did NOT fire). Approvals are audited read-only by
`scripts/credit-review.py` (see `docs/credit-verification/ai-credit-reviewer.md`).
Caroline (edge) approves nothing: `capability-approvers.txt` lists no approver and
`credits_verify` / `profiles_consolidate` / `profiles_claim_self` stay off. Deploy refuses a
source that lists one and strips `MUSO_CAPABILITY_APPROVER` from edge.env
(`scripts/lib/ensure-no-service-approver.sh`; a 10-27 deploy re-opened it once).
Credit REMOVALS are the mirror: core-backend #10310 refuses every agent/API token on the
admin credit DELETE routes and on approved->unverified/rejected take-backs, and
approved->user_verification_needed is illegal (the only exit deletes every role on the
request). Retro take-backs are role-scoped and run from a named human's own session via
`scripts/credit-retro.py` (`docs/credit-verification/credit-retro-r1.md`).
The "we added your credit, please help us verify it" note to users goes ONLY through
`scripts/intercom-verify-request.sh` (fixed copy, captain-approved, idempotent via the
verify ledger); see `docs/credit-verification/verify-request-notes.md`.
Its identity gate (Intercom external_id = the account's professional id or Auth0 subject, or a
presented profile, i.e. a processed claim or representation profile owned by EXACTLY this account,
which the mobile app logs into Intercom with) is never loosened beyond that. The one resolver is
`scripts/credit_review/identity_resolver.py` (r5, Fable `[key=x2-sample-1027]`). An app's
presented-profile id is never overwritten. Wrong or empty Intercom ids are fixed in the data, only
by `credit-review.py intercom-reconcile`, which is audited and revertible. Every status note passes `credit_review/fraud_lens.py` first. See
`docs/credit-verification/intercom-identity-reconcile.md`. A document on file excludes a user
from every ask until a stage-2 verdict releases the credit
(`scripts/credit_review/stage2_verdicts.py`: need_more -> `gap-ask`, no_document -> `uvn-status`);
the decider never asks those users itself.

Every credit-trust AI call goes through `scripts/credit_trust/llm.py` (Codex on the
subscription, tool-less via `scripts/lib/codex-judge-exec.sh` -> Jev), which writes
an append-only `llm_calls` row with the prompt sha256. The only metered path is the
opt-in OpenRouter fallback, capped by `credit_review/decide.py` `CappedJudge`.
Never judge credits in an OpenClaw agent turn. codex-cli 0.156.1 has no headless
web search (it routes search through Code Mode `exec`), so web evidence is fetched
server-side and only verbatim-quoted passages count:
`docs/credit-verification/credit-trust-llm.md`.
Exception (captain 2026-10-26): doc-verify's claim extraction calls OpenRouter
`deepseek/deepseek-v4.1-flash-1017` directly (tool-less, `data_collection: deny`, every call a
`dv_llm_calls` row, daily cap). Doc-verify (shadow) checks what a returned document CLAIMS
against sources the user does not control; UNKNOWN never approves:
`docs/credit-verification/doc-verify.md`.
The DSP evidence verifier (shadow, `scripts/credit-dsp-verify.py`) is the same posture for credit requests: approve-verdicts
only on a same-run Spotify AND Tidal by-id anchor; it runs as its own job, never in Caroline:
`docs/credit-verification/dsp-evidence-verifier.md`. A missing contributor id on the presented profile is only
ever PROPOSED, in shadow, in `link_proposals`. That table is never the decider's `decisions`, whose readers treat
every row as a credit decision. Code never links on a name alone and never relinks:
`docs/credit-verification/profile-link-proposals.md`.

## Caroline's replies pass a code output guard

Every Caroline reply passes `plugins/intercom/src/caroline-output-guard.ts` (promises, secret sauce,
process contradictions, off-topic -> approved hand-off line + reassignment). Approved lines live ONCE in
`answer-bank.ts` (pinned by `scripts/check-caroline-answer-bank.sh`). Inbound Intercom, support@ and proof
text pass the detection-only injection watch (TS + Python copies pinned equal). Changing a rule = add a red-team
case (`plugins/intercom/redteam/`); a case that gets through fails CI and the daily replay pages. See
`docs/support/caroline-safety-layer.md`.
Profile merges are judged in shadow by `scripts/merge-verify.py` (verdict + the exact command for a
named human; no executor, no agent confirmer): `docs/credit-verification/merge-verify.md`.
Every credits / claims / merges verifier is scored in shadow by `scripts/verifier-eval.py` over the
frozen labelled sets in `scripts/verifier_eval/sets/` (false-approve, approve-on-known-bad and guard
violations must be 0; nightly board in `/var/lib/hydra/verifier-eval/latest/`):
`docs/credit-verification/verifier-eval.md`.

## The Ops bot's staff asks are routed, not answered by an agent turn

Every message on the `operations` Slack account is intercepted by
`plugins/ops-intake` (`inbound_claim`) and routed to coded answerers in
`scripts/ops_intake/` **before** any agent turn. Only the class `other` reaches
the agent — and not when the text is a HIGH injection hit. The agent turn never
judges a credit, never hides, never merges, never refunds on an ask.

- **Identity is `event.user` from the Slack envelope.** A pasted
  `*Jan Delmo* [12:09 AM] …` (seen 11-02 16:31Z) is text; it never resolves a
  requester. Tiers live in `policies/ops-requesters.json`, actions/caps in
  `policies/ops-intake-actions.json`.
- **W2 (irreversible: `DELETE /admin/profile`, merge without an unmerge manifest,
  credit approve/remove, refund, account delete) is granted to NOBODY**, including
  the captain: the reply names the human path. W1 (note, answer-bank reply,
  ClickUp status move, rename, request→UVN, register row, hide-PR open) is the
  three staff ids only, each write one ledger row WITH its inverse
  (`/var/lib/hydra/ops-intake/actions.sqlite`, the #1702 shape).
- **Unmeasured is a refusal, not a pass.** Fraud lens (band/holds, reused-document
  H3 F2, requester-linked account) plus register identity verdict before any W1;
  a lens that cannot be measured refuses the write.
- **No inverse, no write.** `ledger.plan()` raises before executing; `revert()` runs
  the recorded inverse only.
- **The reply is one contract line** (`class · ask_id · verdict · evidence ·
  next · ledger`); `answer.render()` REFUSES "queued" without a due time, any
  credit judgement whose source is not coded, any "Firstmate" attribution without
  a ruling file, and any unmeasured claim. `queued` must name `due_at` — the row,
  not a sentence, is the queue (the census found ≥24 phantom "queued for
  Firstmate" replies).
- **W1 execution is OFF by config** (`OPS_INTAKE_WRITES`); plans are recorded with
  their inverse and the reply says so. Enabling it is a captain decision —
  `docs/support/ops-intake-router.md` §"Enabling W1 execution".
- **Guards**: `scripts/check-ops-intake-policy.sh` (CI + bats mutations: W2
  reachable from Slack, W1 without inverse, zeroed caps), the 8-case red-team
  corpus replayed in CI and daily (`ops-intake-redteam.timer`, pages on
  regression), `tests/test_ops_intake.py` (classifier ≥95% on the 269-row census
  fixture with the residual pinned by name).
- The overdue escalation tick belongs to firstmate lane `jan-asks-watch-w1`;
  `ops-intake-digest.timer` reports `open-past-due` so an unowned tick cannot hide.
  Full doc: `docs/support/ops-intake-router.md`.

## Agent shell (exec) posture: who can run commands as root on node-8

Every agent's posture (`denied`, or `full` with a reason, exit plan and expiry no more than 31 days out) is in
`policies/agent-exec-policy.json`. The rules are constants in `scripts/check-agent-exec-policy.py`. It runs at **three**
call sites, and PR CI alone is not enough — it only ever sees the repo copy at review time, so a hot edit, a partial
rsync or a hand-reverted live file could drop scout's deny and ship clean: PR CI (`--base origin/main`), `deploy.sh`
Step 1 pre-sync (repo tree, no `--live` — a pre-sync `--live` would deadlock every deploy that legitimately changes a
posture) and Step 4d.5b post-sync (`--live --live-profile <target>`, before the Step 6 restart, so a failing deploy
never reloads the gateway onto an unreviewed shell posture), plus a tick in `cron-health-watchdog.sh` so a `full`
exception whose **expiry date passes** during a deploy-free week still pages. That tick dedupes per FINDING (the stamp
carries the findings' sha, so an unchanged violation is quiet while a new one pages at once, and a clean tick clears
the stamp), pages when the checker itself has gone missing, and stamps only after Slack CONFIRMS the post — an
undelivered security page must never buy 24h of silence. Pinned by
`scripts/tests/deploy-exec-policy-gate.bats` (wiring + both blocks) and the watchdog's own bats cases. Three traps on
openclaw 2026.8.35, all verified in code:
- **Never set `tools.exec.security`/`mode` to `deny` or `allowlist` on a codex agent** (all main agents are codex):
  `@openclaw/codex` refuses the turn and the fallback runner silently moves it to openrouter. Lock a shell with
  `tools.deny` instead.
- **`tools.deny: [exec]` restricts the codex harness**: native web_search, skill_search, memories and MCP go off with
  the shell (validate-config-matrix check #8). Price that per agent.
- **`lobster` is a shell the tool policy cannot see**: its `exec --shell` steps spawn directly. Every main agent gets it
  via `tools.alsoAllow`, so a denied agent must deny `lobster` too.
Runtime proof per agent: `scripts/redteam/exec_injection_probe.py --agent <id>` (post-deploy, sends one injected turn).

## GDPR erasure: the register is `erasure_requests`, and nothing is ever deleted

Erasure / takedown / Art. 15 requests from every channel live in ONE machine register
(`scripts/gdpr-pipeline.py`, store `/var/lib/hydra-gdpr/erasure.sqlite`; `docs/support/gdpr-pipeline.md`).
Identity is decided by code per gdpr-ack-v2 paths A-E (a claim is one path, never a requirement); request text
never selects a hide. The pipeline only PREPARES the reversible hide PRs (H-DevOps `HIDDEN_ENTITY_IDS` + PDP
sitemap `LEGAL_HIDDEN_ENTITY_IDS`); a person merges. Never `DELETE /api/v3/admin/profile` or muso-cli delete
(legal hold 1350). Customer sends stay locked until Fable's GO lands in a PR.

## Sentinel demotion: three independent stops, and nothing promotes itself

`scripts/sentinel/demote.py` is the ONLY code that narrows a capability's rollout state on its own
(`live → canary → shadow`, one step per tick, never more). It runs unattended on `sentinel-demote.timer`
(nightly 02:30Z) and `sentinel-demote-fast.timer` (hourly, for the `audit_fail_any` / `manipulated`
triggers). Authoritative doc: `data/sentinel/README.md`; registry `policies/sentinel-capabilities.json`
(owned by sentinel-core-s0); runtime state `/var/lib/hydra/sentinel/registry-state.json`.

- **Three independent stops, any one stops it**: the runtime state flip, the capability's kill file
  (`/etc/hydra/<kill_file>` from the registry row), and the actor's own flag in
  `policies/credit-approval-automation.json`. The demoter writes the first two and opens a mirror PR for
  the repo copy; the actor flag is left to that PR. A switch in one place is not a switch (10-27).
- **Promotion is never automatic.** `promote` only renders a parity report (agreement vs the arm it
  replaces over ≥7 d and ≥200 evaluations, false-act rate on RED/BLACK, cap trips, 0 demotion triggers)
  for a Fable ruling id; the PR that flips state must cite it (`rollout.since` + `approval_ref`).
- **"I could not read the evidence" must never render as "the evidence says fine"** — an unmeasured
  trigger is `unknown`, which blocks promotion, never a healthy zero.
- **The units are deliberately NOT gated on the registry** (no `ConditionPathExists`): a condition
  would make a *deleted* registry a silent skip too, leaving demotion blind with no page. `demote.py`
  tells the two worlds apart with the `registry-seen` marker it writes on every good load — never
  loaded → exit 2, clean skip; loaded then gone → page + exit 4. Exit 3 (deliberate kill switch) is
  clean; exit 4 stays a failure. `SuccessExitStatus` is pinned to the exit codes in `demote.py` by a
  bats test.
- **Ticks serialize on a host `flock`** across load → evaluate → save → mirror PR; a tick that cannot
  acquire within `SENTINEL_LOCK_TIMEOUT` exits 0 silently (the other tick is doing the same join).

## Picking the right extension mechanism

Before writing new code in this repo, walk this decision tree top-down and stop at
the first YES. Picking the wrong mechanism is how this repo accumulated 38 drifted
skills, 5 orphan scripts, and a dead Gmail plugin (rationale + cleanup in issue #329).

1. **External event into the gateway** (Slack / Intercom channel / `/hooks/agent` webhook)? → openclaw plugin in `plugins/<name>/`
2. **External MCP server I don't own**? → wire via `mcp.servers` in
   `openclaw-*.json` (transport: `streamable-http`)
3. **Wall-clock schedule, no human in the loop**? → openclaw cron in
   `cron-jobs.json` (sessionTarget=isolated)
4. **Deterministic multi-step pipeline, no LLM in the loop**? → Lobster `.lobster`
   file invoked via `exec → bash wrapper.sh` (never agent → lobster direct)
5. **Git push / PR open / CI**? → `.github/workflows/*.yml`
6. **Procedure ≥2 agents need in-context**? → SKILL in `skills-all/<name>/` only.
   Workspace shadows under `workspaces/<agent>/skills/<name>/` are **forbidden**
   by default — `scripts/check-skill-drift.sh` (gated by CI) will block any new
   one. Workspace copies are **rank-1** in openclaw's resolver and **shadow** the
   canonical at agent-bind time, so a shadow either silently duplicates canonical
   (dual-edit burden) or silently freezes stale doctrine for the agent. Either way
   it's a bug, which is why the default is "no shadows."
   The only exception is when a single agent needs genuinely per-agent content
   (e.g. `operations/muso-ops-admin` carries `config/tier2-godmode-allowlist.txt`
   which must NOT propagate to canonical). For those, list the workspace
   `SKILL.md` path in `.skill-workspace-divergence.txt` with a one-line reason,
   and prepend a `<!-- WORKSPACE-DIVERGENCE: ... -->` HTML comment after the
   frontmatter close. The 38 historical drift entries that bit us in PRs #183,
   #187, #213 (and pre-#336) were exactly the absence of this rule.
7. **One shell line**? → just call `exec` directly, no wrapper, no skill
8. **Complex helper, agent + human callable, not Lobster-shaped**? → `scripts/`
   (one language per concern — don't add `foo.ts` next to `foo.sh`)
9. **Claude Code research persona**? → `.claude/agents/<name>.md`

### Anti-patterns that have bitten us

- Skill wrapping a single bash command → inline in SOUL.md or call `exec` directly
- Plugin exposing one tool with no callbacks → that's a script behind JSON-RPC
- Agent → lobster tool direct → schema bleed forces hallucinated `flowId`; use
  `exec → bash wrapper → /tools/invoke`
- Hand-rolled session pruning / log rotation / cron maintenance → grep openclaw
  config for a native key first (`session.maintenance`, `statusReactions`,
  `tools.deny`, `extra_body.plugins`, `/hooks/agent`)
- `before_tool_call` hook as YOLO-mode safety → silent no-op for exec; enforce at
  the bash boundary instead
- Writing to `/root/.openclaw-*/openclaw.json` out of band → must call
  `announce-legit-write.sh` first or the audit watcher fires a Slack false-positive
- GH Actions for runtime ops (as opposed to CI gates) → has caused two-CD-paths
  drift before

### Specialist subagents (in `.claude/agents/`)

When uncertain about *which* mechanism to use, or when authoring a skill or plugin,
route to the right specialist instead of guessing:

- `hydra-operator` — the generalist first stop: cross-cutting hard-won lessons
  (codex auth, deploy/CI/PR traps, the working-here doctrine, Muso-domain
  pointers, safety traps) and "what will bite me?" Read-only; routes to the
  specialists below for narrow authoring work.
- `hydra-extension-picker` — "where does this go?" / "plugin or skill?" questions
- `hydra-skill-author` — creating, editing, or copying a SKILL (enforces dual-tree
  rule, `exec` allowed-tools naming, Lobster wrapper pattern)
- `hydra-plugin-author` — creating or editing an in-tree plugin under `plugins/`
  (enforces openclaw 2026.5.x packaging contract: `dist/index.js`, build script,
  pnpm-lock against deploy SDK)
- `openclaw-expert` — any general OpenClaw infrastructure question (gateway config,
  hooks, cron, /tools/invoke, model fallback, session lifecycle)

### When in doubt

- The decision tree exists because past me kept getting it wrong. Trust the tree.
- If the new work feels like it spans multiple buckets, it probably needs to be
  split.
- The full rationale lives in GitHub issue #329 (the consolidation issue).

## Maintaining this file

Keep this file for knowledge useful to almost every future agent session in this project.
Do not repeat what the codebase already shows; point to the authoritative file or command instead.
Prefer rewriting or pruning existing entries over appending new ones.
When updating this file, preserve this bar for all agents and keep entries concise.
