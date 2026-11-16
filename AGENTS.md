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
release stay decoupled: the tag + announcement is a labeling event after the
fact, never a gate. **Merging to `main` does not deploy**: `deploy.yml` runs on
a 05:38Z schedule or a dispatch only, so a merged fix is not on node-8 until a
deploy run SUCCEEDS on a head containing it (`/opt/hydra/.deployed-sha`). Where
delivery hours go, and the standing rules: `docs/delivery-velocity.md`
(`scripts/cycle-time.py` measures it).

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
- **A metered model id must also be inside `ZDR_ROUTING.max_price` ($0.30/$1.20
  per M), or OpenRouter refuses EVERY call it makes.** The cap is a spend
  decision and it is not the thing to raise: on 2026-11-04 the credit-review
  crons pinned `x-ai/grok-4.3` ($1.25/$2.50, 4x the ceiling) and 204 model calls
  were blocked in 24h with the balance at $289. `MeteredModelPriceCapTests`
  (`scripts/tests/test_credit_review.py`) now asserts the judge default,
  `batch_judge.OPENROUTER_MODEL` and every `--model` in `cron-jobs.json` are
  priced in `PRICE_USD_PER_TOKEN` and under the cap. A cron `--model` beats
  `CREDIT_REVIEW_MODEL`, so the argv is the pin that matters.
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

**A test class defined below `unittest.main()` never runs in CI.** PR Validation invokes most
Python suites as `python3 scripts/tests/<file>.py`, and `unittest.main()` discovers only the
classes that exist when it is called — so a class appended after the `__main__` block is
invisible on the path CI uses, while `pytest` (which collects the whole module) still runs it.
Found 2026-11-06 on #1766: `test_credit_decide_watchdog.py` ran 38 of 52, `test_doc_approve.py`
122 of 125, `test_doc_verify.py` 209 of 215 — all reporting OK. Keep the `__main__` block the
LAST statement; `scripts/tests/test_ci_test_discovery.py` (wired into PR Validation) scans every
file the workflow invokes that way and fails if anything follows it or if direct invocation runs
fewer tests than pytest collects.

**GitHub grades a required check by the NEWEST workflow run that posted it, and a title/body
edit starts a run.** That run does not re-run the suite; its `validate` mirrors the head's real
suite (`scripts/ci/validate-mirror.py`: it waits for a running suite, and for a retarget's or
reopen's new run that has not listed its suite yet, and exits 0 only when the newest real one
succeeded). Until 2026-11-13 it read once and failed, so an edit made inside the
six minutes after a push left a validated head unmergeable (6 of 50 merged PRs, measured in
`data/pr-pipeline-unblock-f1/report.md`). Still: get the body right at open
(`scripts/pr-doctor.py preflight --body FILE` runs the credit guard's own section check) rather
than editing after the push. **What is holding a PR, and the cheapest correct way to clear it,
is `scripts/pr-doctor.py plan <pr>`** (`--apply` performs re-runs of failed jobs only). An edit
run also posts a skipped check for every other job of the suite, and `gh pr checks` keeps one row
per name, the newest: after an edit a `skipping` row says nothing about the suite's own job of
that name. Read the suite run's jobs (`plan` does).

**Never push an empty commit to re-trigger CI.** Every Actions check here can be re-run in place
for 30 days (`gh run rerun <run> --failed`), which keeps the head and its QA verdict. A re-run
reads the SAME merge commit as the original run, so it clears an interrupted run or a flake;
`gh pr close <n> && gh pr reopen <n>` fires `reopened` and validates the head against today's
`main`. A retarget onto `main` starts a full validation by itself (`edited` with `changes.base`);
a push made while the base is another branch starts none (`branches: [main]`), and a conflicting
head starts none at all.

**A validated head held by a stale red is re-run by `pr-rerun-sweep.yml`, not by a person.** It runs
`scripts/ci/pr-rerun-sweep.py` when a PR Validation run completes and every 2 h: the planner's own
re-run (`pr-doctor.plan_pr`), one per PR per pass, at most twice per run, with `actions: write` as
its only write. It never re-runs a suite that FAILED and cannot edit a PR, so a head whose required
check is "expected" (an `edited` event clears it) stays a person's. `validate-code: skipping` in
`gh pr checks` is an edit run's placeholder, never proof a head is unvalidated: on 2026-11-13 it
was read as nine unvalidated heads when none was (`data/validate-code-stuck-sweep-v1/report.md`).
Off switch: repository variable `PR_RERUN_SWEEP_DISABLED=1`.

**Before concluding a rebase erased base work, check the base first.**
`git rev-list --left-right --count origin/main...HEAD` — a stale base makes `main`'s newer work
look like deletions in `git diff origin/main`, and "restoring" it with
`git checkout origin/main -- <file>` then breaks the branch against its own older `decide.py`
(`AttributeError: module ... has no attribute ...`). Rebase, then re-read the diff.

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
`approved_by` + `approval_ref`. A cron whose `/etc/hydra` kill file is present is
HELD: `policies/held-crons.json` + `scripts/check-held-cron-guard.py` (pre-commit
`--staged`, PR Validation `--base`) refuse a diff that flips its `enabled` to true,
changes its schedule or payload, deletes its row, or drops its registry entry
without the recorded step's `[key=kill-lift-MMDD-HHMM]` on a line naming that cron
plus the executed step's record at `data/kill-lift/<key>.evidence` (which the node-8
hand-off job's `--host` run confirms against the host: kill file gone, record
byte-identical), or adds a code line that deletes a literal `.disabled` path; the lift itself is
`scripts/credit-approve-hold-lift.sh` (print-only) and the rules (R1-R6) live in the
guard's docstring. The Lobster batch also re-checks that flag at
dispatch and at the write boundary. Why: from 05-18 to 10-11 the batch approved
validator-DECLINED credits through an inverted rule (`approve_owning_track == 100`
means the shortcut did NOT fire). Approvals are audited read-only by
`scripts/credit-review.py` (see `docs/credit-verification/ai-credit-reviewer.md`).
**The account gate's `allow` is not "green"**: it allows an amber (fraud watch) account, so an approver
that reads only `allowed` approves the watch. Read the band: `account_gate.watch_refusal` (score-approve
approves a green allow only; an allow that names no band is unmeasured, never green).
Caroline (edge) approves nothing: `capability-approvers.txt` lists no approver and
`credits_verify` / `profiles_consolidate` / `profiles_claim_self` stay off. Deploy refuses a
source that lists one and strips `MUSO_CAPABILITY_APPROVER` from edge.env
(`scripts/lib/ensure-no-service-approver.sh`; a 10-27 deploy re-opened it once).
EDITS to a credit already on a profile (not approvals) go through ONE guarded write
path, `scripts/clickup_drain/write_path.py`: shared kill files + one lock + 100 writes
per UTC day across every queue drainer + a ledger row carrying each write's before/after
role list. Two invariants are code, not prose: the budget FAILS CLOSED (an
unreadable `writes.json` stops the run instead of reading as "zero writes today"),
and "the admin API could not answer" (`Unavailable`) stops the run WITHOUT tagging
the ticket, while a wrong row refuses the whole batch as `blocked` — turning an
outage into a verdict is how a transient 503 parks a customer's ticket forever.
The first drainer is `action:bulk-credit-change`
(`scripts/clickup_drain/bulk_credit_change.py`; cron `clickup-drain-bulk-credit-change`
ships UNARMED - no `--apply`, `enabled:false` - and arming it is a captain decision, not
a merge). It reads `details.bulk_rows`, validates every row BEFORE any write,
read-backs every row after, tags `complete` only when all verified and `partial` +
one internal comment otherwise (partial is never a close, and this path never messages
the customer, never writes a ClickUp status), and has NO removal capability at all:
`--revert` prints a plan, because `muso-admin-api.sh enforce_removal_gate` refuses
credit-removal DELETEs, so an undo is a named human's job via
`skills-all/muso-ops-tracks` (Removal Requests). See
`docs/credit-verification/bulk-credit-change-drainer.md`.
Credit REMOVALS are the mirror: core-backend #10310 refuses every agent/API token on the
admin credit DELETE routes and on approved->unverified/rejected take-backs, and
approved->user_verification_needed is illegal (the only exit deletes every role on the
request). Retro take-backs are role-scoped and run from a named human's own session via
`scripts/credit-retro.py` (`docs/credit-verification/credit-retro-r1.md`).
Customer-initiated removal is TWO intents, never one: `hide_mine` (the owner's right: a
served-visibility hide, no verification, reversible) and `not_me` (a claim on the removal gate, which
decides on the live public-credit rule). `scripts/clickup_drain/credit_removal.py` +
`scripts/credit_review/removal_executor.py` execute them from ClickUp under `credit-removal@hydra-ops`,
with identity resolved from the VERIFIED Intercom contact (never the ticket text), every write on an
append-only ledger with an inverse, and `--revert <run_id>`. It decides no removal and calls no
catalog delete: while core C1/C2 are unmerged every row is `authority_unavailable` and nothing is
written (`docs/credit-verification/credit-removal.md`).
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
A "review the proof" ask is answered by code, not by an agent turn: `scripts/ops_intake/proof_review.py`
(one verdict per request from H3 + doc-verify + the DSP anchor + the fraud lens, one next step, one
reply card). It approves nothing and builds no customer message - a SUFFICIENT verdict is recorded as
`waiting_route` until a captain decision creates an approval writer (`policies/proof-review-route.json`).
See `docs/credit-verification/proof-review-coded.md`.

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
`docs/credit-verification/dsp-evidence-verifier.md`. Its built anchor records reach core by the `credit-anchors-push`
cron (upload only, approves nothing; a run with nothing built is a clean `nothing_pending`); whether the scheduler ran
it is `credit-anchors-push.py --scheduler-runs`, never a hand-run: `docs/credit-verification/dsp-anchor-record.md`
§"The scheduled upload". A missing contributor id on the presented profile is only
ever PROPOSED, in shadow, in `link_proposals`. That table is never the decider's `decisions`, whose readers treat
every row as a credit decision. Code never links on a name alone and never relinks:
`docs/credit-verification/profile-link-proposals.md`.

## Claim documents get one recorded decision, in shadow, and none of them is a person's

`scripts/claim-doc-ladder.py` (`claim-doc-ladder.timer`, every 4 h) is the claim twin of `doc_approve.py`: every open
claim with a document on file gets ONE row in `/var/lib/hydra/claim-doc-ladder/decisions.sqlite` with an outcome, a
reason code and who moves next. Operator doc, the reason-to-ask table and the revert per field:
`docs/credit-verification/claim-doc-ladder.md`; the measured population under these rules, on a fixture:
`data/claims-no-human-p1/report.md`.

- **Four outcomes, no staff queue** (captain 2026-11-13): `approved`; `refused` (a document was read and does not
  prove the claim: the row carries the internal reason AND the ask, what to send instead); `resend` (doc-verify's
  last answer read nothing: the ask is a copy we can read, and it is no refusal); `awaiting_read` (WE have not read
  the document or a fact: no verdict, no ask, and the row names the job that owes the read).
- **A new reason needs its ask or its route in `doc_ladder.REASONS`, or the module does not import.** The reason
  code is never an input to the words a claimant reads (`ask_text`); the words are `policies/claim-doc-asks.json`,
  which does not load with an ask missing, an unknown ask, or copy that names an identity document.
- **An unread document is ours and never a refusal.** Whether a job will still read it and whose failure the last
  read was are doc-verify's own rules (`runner.extract_settled`, `gate.TOOLING_ERRORS`), read by `doc_sources` as
  `read_final` / `tooling_error`. Do not write either rule again. One unread document keeps the whole claim
  `awaiting_read`: the claimant is asked for nothing while the unopened document may be the proof.
- **A route names a job, and whether that job is switched on is read, never assumed.** Each route is one row in
  `doc_ladder.ROUTES` carrying the script and the schedule: `doc-verify` and `byte-restore` are crons
  (`credit-doc-verify`, `credit-doc-verify-blob-backfill`, checked against `cron-jobs.json` by a test), and
  `doc-sources` is the `claim-doc-ladder.timer` pass whose launcher a test executes. **`credit-doc-verify-blob-backfill`
  ships `enabled: false`** and has its own kill file (`/etc/hydra/credit-doc-verify-blob-backfill.disabled`): arming
  it is a separate change, and until then `doc_ladder.job_state` makes every `byte-restore` row read `job: disabled`
  in `report`, `list` and `latest.json`. A file that cannot be read is `unread`, never `enabled`. A route naming
  neither a cron nor a timer unit refuses to register. No route names a command a person runs, and no route
  pretends the ladder reads a document.
- **A waiting row keeps its age.** An `awaiting_read` row keeps the day it was first decided, so `report`, `list`
  and `latest.json`'s `awaiting` carry how long it has waited, per route and reason: a loop with no read and no
  age looks like work.
- **Paying claimants first.** Claims are decided, recorded and listed in `doc_ladder.paid_first` order: a measured
  `paid: true`, then everyone else, then by claim id. An unread paid flag sorts with the unpaid.
- **A document of a kind the claim never accepts is refused on its kind**, even when it parsed and said nothing:
  asking for a readable copy of a kind we never accept is a circle.
- **It records and nothing else.** No executor, no admin API call, no message: an ask on a row has been sent to
  nobody. A sender is a row in `policies/outbound-copy-senders.json` behind the outbound copy gate; an executor is
  a `policies/credit-approval-automation.json` row and a recorded captain decision.
- **The predicates decide; the model's part ends at the extraction**, which is the one doc-verify already recorded.
  The ladder does not extract and starts no read. doc-verify reads a filing with no candidate credit request when
  its account has an open claim (`runner.claim_only_docs`: the extraction only, no key, no H3, no outcome row).
  They get the room the credit filings leave and a floor of 5 per worker on top of `--max-docs`
  (`runner.claim_only_room`; the room alone read 0 of 116). A failed open-claims read selects none and is a run
  error, never "nobody claims".
- **No document, no decision; unmeasured is its own reason, never a pass and never a refusal.**
- **A credits page is not accepted and a document must name a release on the profile**
  (`policies/claim-doc-ladder.json`): without those two the first real run approved 15 claims, 11 on a public page.
- **Page ids are compared by `scripts/lib/page_identity.py` only** (equality, or a truncated prefix of 8+
  characters); names by `credit_review.roles.names_match`. Do not write either rule again.
- A differing decision replaces the row, a refusal included (the claimant answered the ask). The one exception: an
  `approved` row is not replaced by `awaiting_read`; that is logged once as `drift`. `release` is an operator's
  undo, never a step a claim waits on.
- The first pass on a store the older ladder wrote sets its rows aside whole (`claim_doc_decisions_cdl1`) and
  decides every claim again: `needs_human_review` and `unreadable` rows are not carried over.
- A pass retires every standing row it did not decide (the claim closed, or its last document left the file), so
  `list` shows open claims only. That is why an open-claims read or a `proof_intake` with no rows raises instead of
  reading as "nothing is open": an empty answer would retire the whole store.

## Caroline's replies pass a code output guard

Every Caroline reply passes `plugins/intercom/src/caroline-output-guard.ts` (promises, secret sauce,
process contradictions, off-topic). A refusal is explained to her and she retries ONCE through the same
guard (`guard-feedback.ts`); only a second refusal posts the `ai_queue_fallback` line, and the conversation
stays with her. The status line needs an `open_request` fact MEASURED in the same turn by one of her two
own-row reads (`credit_verification_check`, `profile_claim_status`: fail closed without a signed-in
contact; `profile_credits_status` stays denied because a typed id selects any profile). Unmeasured is not
false. A model-written promise of a person is removed at send (`unbacked-handoff.ts`), merge threads
included, and any phrasing that strip misses is refused by the guard rule `person_without_assignment`,
which is UNCONDITIONAL: no fact can back the sentence, because nobody can be assigned (the escalation
team has no members) and neither reply door nor the Ops bridge can assign. The escalation therefore
says what it recorded and then moves the conversation to the escalation queue, never that a person is coming. Resolution rate and still-waiting are read daily by
`scripts/support-resolution-daily.py` (`docs/support/resolution-daily.md`): a bulk sender's holding copy
must be added to its rules or it reads as resolutions (2026-11-12: 13.9% read as 24.9% with nothing
deployed). Approved lines live ONCE in
`answer-bank.ts` (pinned by `scripts/check-caroline-answer-bank.sh`). Inbound Intercom, support@ and proof
text pass the detection-only injection watch (TS + Python copies pinned equal). Changing a rule = add a red-team
case (`plugins/intercom/redteam/`); a case that gets through fails CI and the daily replay pages. See
`docs/support/caroline-safety-layer.md`.

**The Ops bot's summarize/resolve asks are code now, and the same guard covers them.**
`scripts/ops_intake/summarize.py <conversation_id>` prints a facts card built only from code reads
(account r5, request statuses, claims, merges, erasure row, verify ledger, subscription, ClickUp) with
at most one tool-less 40-word intent label; the suggested resolution is a LOOKUP in
`policies/ops-resolutions.json`, never a judgement, and the card prints the RULE KEY so a wrong
mapping is a one-line PR. The card and the lookup are wired into the router's `summarize-resolve`
answerer (`answer.answer_summarize_resolve`), which **executes nothing**: it returns a `WriteRequest`
and the router's step 9 is the only executor (tier → fraud lens → caps → `ledger.plan` with the
inverse → writer). Do not add a second executor — `router._production_writers()` returns `{}` by
captain decision, so a direct write would perform behind a gate a human closed. An UNREADABLE fact is
`unknown` and falls through to the hand-off — "0 open requests" and "could not read the requests" map
to different actions, so never coerce one to the other. The intent label goes through
`guard.Guard.call`, not the raw judge: `call` is what raises `CanaryLeak` when the model echoes the
prompt frame, and a leak fails the ask closed. Every customer reply leaves as an answer-bank line
through the REAL `caroline-output-guard.ts` (a Python caller shells out to it; never port it) and then
`scripts/intercom-ops-write.sh reply --customer-facing --approved-by <requester>` (pinned identity,
leak refusal, api-log before POST) — never a hand-composed `/conversations/{id}/reply`. A guard that
cannot run sends nothing. `docs/support/ops-summarize-resolve.md`; pinned by
`tests/test_ops_intake_*.py`, `scripts/tests/ops-intake-guard.bats` and
`scripts/check-ops-resolutions.sh` (CI: the lookup stays closed).
Profile merges are judged in shadow by `scripts/merge-verify.py` (verdict + the exact command for a
named human; no executor, no agent confirmer): `docs/credit-verification/merge-verify.md`.
Every credits / claims / merges verifier is scored in shadow by `scripts/verifier-eval.py` over the
frozen labelled sets in `scripts/verifier_eval/sets/` (false-approve, approve-on-known-bad and guard
violations must be 0; nightly board in `/var/lib/hydra/verifier-eval/latest/`):
`docs/credit-verification/verifier-eval.md`.

## Intercom: no conversation is assigned to a person by default

The AI queue is "assigned to Caroline" (admin `5763097`); Intercom has no AI team. Who holds a
conversation is decided in ONE module, `plugins/intercom/src/assignment-policy.ts` (captain
2026-11-11; measurements in `data/intercom-no-human-assignment-k1/report.md`):

- **A blocked, dropped or leaked reply stays with Caroline.** The customer gets
  `BLOCKED_REPLY_FALLBACK` (bank entry `ai_queue_fallback`, which promises no person) and nobody is
  assigned. Before this, 404 of the 478 conversations the plugin put on one person in 14 days were
  Caroline's own reply failing the output guard.
- **A human only on an explicit escalation, and an escalation carries a reason**
  (`applyHandOff` throws without one). It goes to the TEAM queue `escalationTeamId` with
  `type: "team"`, never to an admin id. `defaultInboxId` is retired and ignored;
  `scripts/check-intercom-no-personal-assignee.sh` (PR Validation) fails on it, on a person's id as
  the escalation queue, and on any use of `assignConversation` outside the policy module. That
  scan is a tripwire (a computed call can dodge text): the rule itself is `assertAssignmentTarget`,
  which makes every client refuse an admin assignee other than "0" or the acting bot.
- **No escalation outcome is assumed.** `applyHandOff` reads the conversation back after EVERY
  escalation, accepted requests included, and reports only what the read shows: `failed` while
  any admin (the bot included) holds it, when it sits in another team, or when it cannot be read.
- **A human assignee silences Caroline only while that human is ANSWERING the customer**
  (`humanHold`): a reply with words inside `humanHoldHours` (72), and no customer message left
  without one for more than 4 h. A bare close, note or assignment is not a reply: on 2026-11-11 a
  bulk close counted as "working the thread" and silenced her for 72 h on every customer who wrote
  back. An escalated thread on a person is the exception: `escalationFiredAt`, set on every escalation
  this plugin fires (the seven-reason rules, a judge verdict and the legacy regex path alike), holds it for
  the whole window, and the 4 h grace never reclaims it. Hand-back
  from the escalation queue is "assign to Caroline".
- **Only a reason outside Caroline's authority leaves her** (`QUEUE_ESCALATION_REASONS`: the seven
  content rules). "I want a human" and the turn cap are answered by her (`escalationGoesToQueue`,
  captain 2026-11-13); the queue's team has no members, so each of those was a promise and silence.
- **A writer outside the plugin that posts as Caroline re-opens the conversation ON its old
  assignee.** On 2026-11-11 one notification campaign re-opened 312 long-closed conversations on a
  person in 52 minutes; no assignment part is written, so an assignment count alone misses it. The
  plugin reclaims on that webhook; a new sender should still assign to Caroline before it posts.
- A ticket (`create_ticket`) is never a hand-off: Caroline's workspace doctrine says so
  (`workspaces/support/AGENTS.md` "Who holds the conversation").
- **A thread handed back to Caroline with the customer speaking last is answered then, not on the
  customer's next message** (`handleWebhookEvent`, `assigned` branch). Only a conversation
  exiting `human_takeover` resumes this way, so the bot's own self-assignment on a dispatch never
  re-sends the message it is already answering; the whole customer-message path runs, guards
  included (restricted accounts, output guard, live check, `canAgentReply`).
- Clearing a person's queue is `scripts/intercom-queue-reassign.py` (plan / apply / revert /
  verify): assignment parts and internal notes only, a ledger row with the inverse before each
  write, never a close or a customer message. `--unanswered-within-days` takes every thread the
  person has not answered, except the classes Caroline cannot answer herself
  (`left_restricted`, `left_escalation_unread`) and every escalation for one of the seven reasons
  outside her authority (`left_explicit_escalation`).
- The sentinel's `intercom_customer_last` counts a thread Caroline answered as the workspace bot as
  unanswered (865 of 1,669 on 2026-11-13). What is owed is read from the parts by
  `scripts/intercom-backlog/drain.py`, which answers it with fixed, gate-approved lines; an account with
  an open request is never messaged by it, a thread with an open promise gets a line only when that line
  is the promised update (`PROMISE_MET_BY`), and a customer-last thread no fixed line can answer is handed
  to Caroline's live turn by ONE internal note per thread — an attempt, not a delivery: the thread is the
  record, and a hand-back with no reply after the note shows as `handback_unconfirmed` on every plan and
  run (24 h window) and is never re-posted. A thread a bot or nobody holds is assigned to Caroline first,
  from the monitor's ONE `non_human_admin_ids`/`staffed_team_ids` rule, never a second list:
  `docs/support/backlog-drain.md`.

## Outbound customer copy passes a signed reviewer gate

Captain 2026-11-12: "check your messages with Fable ... if something was denied, you don't have to tell them why ...
you can always resubmit". Every scheduled customer message asks `scripts/outbound_copy/gate.py check`, which looks
for a verdict **signed by the pinned reviewer key** on those exact bytes (body + subject + campaign + send
frame + rubric sha256). Full doc, the sender list and what is deliberately outside it: `docs/credit-verification/outbound-copy-gate.md`.

- **The mode is per campaign, in `policies/outbound-copy-enforce.json`, and the default is OBSERVE.** Enforce: no
  `approve`, no send. Observe: the message goes (exit 4, `observed`), the review is recorded and the ledger row says
  `copy_review = observed:<state>`. **A signed `refuse`, a code-lint hit and a `retired` frame hold in either mode**,
  and so does a table nobody can read. Only the gate reads the table: no caller, flag or env var picks a mode.
  A campaign moves to `enforce` by a one-line PR citing `gate.py report` (`ready_to_enforce`), one campaign at a
  time; never flip the default. Why: the first real measurement approved 20 of 77 rendered bodies.

- **node-8 can verify a verdict and cannot mint one.** The signing key and the reviewer model (Fable) live on the
  reviewer host only; `scripts/outbound_copy/review_pull.py` pulls held bodies, reviews, and writes verdicts back.
  **If that round does not run, an enforced campaign sends nothing and an observed one goes out unread** - a stalled
  round refuses nothing and fails nothing. It runs as a `systemd --user` timer installed by `scripts/outbound_copy/install-reviewer-host.sh`
  (re-run after any `gate.py` or rubric change: hosts with different default rubrics stop the round, and a family
  rubric the host lacks or holds differently leaves that family unreviewed, exit 1 with `unreviewable` naming it,
  never `ok`: on 2026-11-12 a host without the `gdpr` rubric skipped 68 statutory letters as bad requests), and
  `cron-health-watchdog.sh` pages when the oldest waiting body passes 4h (`gate.py pending-age`), and the page
  says how many of them are held: an observed campaign's backlog is never called a held customer message. A queue it
  has measured and can no longer measure pages too, a `gate.py` that went missing from the host included (an EMPTY
  `CRON_HEALTH_COPY_GATE` is the only disarm).
- **Every visible byte is copy, a list item included.** Markup excuses nothing: what the lint excuses is a VALUE the
  sender declared from the request (`data`: name, role, title, artist), whole-word, once per declaration. A new
  sender whose body carries customer-supplied words passes them as `data` or a song called "Fraud" is held.
- **The verdict names the frame** (`intercom`, `email-template:<key>@<sha256>`). An email template's own words live
  in send-gateway, so the policy pins the sha256 of its reviewed source (`channels.email.template_sha256`) and
  `SEND_JS` re-hashes the live template in the pod before its one POST: no pin or a changed template sends nothing.
- **Every customer sender is one row in `policies/outbound-copy-senders.json`** (`gated`, `gated_elsewhere`, `open`),
  policed by `scripts/check-outbound-copy-gate.py`. `lib/copy_gate.require` and `outbound_copy/sendgate.require_verdict`
  are two callers of the same `gate.py`; a sender uses one, never both.
- **In an enforced campaign, no verdict, a `rewrite`, a `refuse`, a bad signature or a gate that cannot run all hold
  the message.** There is no flag or env var that skips it, and `lib/copy_gate.py` reads none on purpose. A rewrite
  is a proposal for a person to adopt in code; the reviewer's text is never sent.
- **A received or verifying note never says "nothing is needed from you"** (captain bar 2026-10-30): the gate's lint
  refuses it, and the rubric must never ask for it. A rubric that demands what a ruling barred makes the reviewer
  reject the compliant copy - that one line cost 11 of 11 `status-team-review` bodies in the first measurement.
- **A hold is a `deferred` LOG, never a lock** (`verify_ledger.hold_copy_review`): the claim is given back so the
  note is offered again next run. Ask the gate BEFORE any "attempted"/"pending" marker, or a held body burns a
  one-shot attempt or reads as an unconfirmed delivery (duplicate pointer).
- **A new Python sender** calls `copy_gate.require(COPY_CAMPAIGN, message)` as the first statement of the one
  function that POSTs, and adds its campaign to `CAMPAIGN_STAGE`; `test_outbound_copy_gate.py` scans for direct
  Intercom POSTs and fails on one that is neither gated nor argued onto `NOT_BEHIND_THIS_GATE`.
- **A denial is three sentences**: denied for now / verification didn't prove out, "You can resubmit for the credit
  again later.", sign-off. No reason, no accusation word; the code lint outranks the model on both.
- **"No reason" is scoped to risk and fraud denials** (captain 2026-11-15; the rubric's "The two classes"). A
  statement about a document the person sent (class 2: the reason, what would change it, reply here) is the
  `proof-refusal` campaign's fixed sentence and nothing else. Wording exists for three of the five outcomes; do not
  add a pair to the rubric without approved copy.
- **Editing `policies/outbound-copy-rubric.md` voids every verdict signed under it** (a verdict names the rubric's
  sha256): after that deploy every enforced campaign holds each body as `copy_review_pending` until the reviewer
  host is re-installed and signs again. Plan the reviewer round with the merge.
- A message family with other duties gets its own rubric file + `RUBRIC_FAMILY` row (chosen by code, never the
  caller); a listed family with no file is held, never reviewed under the default rubric.
- **A reply no person asked for goes out on the gate's signed approve, never on a person's Slack id**:
  `scripts/intercom-ops-write.sh reply --agent <id> --gate-campaign agent-reply` asks `check` itself and posts only
  on `approved` (an `observed` pass is a hold there; exit 3 `HELD` = queued, run it again). The record names the agent
  and the verdict. `agent-reply` has the `support` rubric. The verdict approves words only: the facts, the right
  conversation and the one-message-a-day claim stay the caller's. Never pass `--approved-by` for a reply nobody read.

## Caroline is measured by one reader, and a promise closes only on a sent message

`scripts/caroline-monitor.py tick` (`caroline-monitor.timer`, every 2h) reads Intercom read-only and is the
ONE place that says what Caroline did: `scripts/caroline_monitor/rules.py` holds every shape rule and every
"she said a person is coming" pattern. Do not write a second classifier; read
`/var/lib/hydra/support-backlog.json` or `caroline-monitor.py report`. Full doc: `docs/support/caroline-monitor.md`.

- **The 30-minute struggle reading is `scripts/caroline_coach.py`** (`caroline-coach.timer`,
  `docs/support/caroline-coach.md`): which touched or waiting threads show a repeated ask, frustration, a loop,
  "I can't ..." (and what), an unbacked promise. It imports `rules` / `collect` / `backlog` and restates none of
  them; a signal is a reason to open a thread, never a verdict, and its files hold ids and signal names only.
- **The number is hand-offs with nobody assigned per week** (1,078 on 2026-11-11, rising). It pages
  `#clio_devops`; a tick that could not read Intercom pages too and never rewrites the file. The first
  unreadable tick is recorded and posts `NOT MEASURED` without paging; `monitor.blind_ticks_to_page`
  (2) decides when it pages.
- **Communicating back to users is NOT satisfied by this change**: the ledger queues a due promise
  (`commitment_outbox`, held until the copy gate `outbound-copy-fable-gate-v1` and the driver in
  `scripts/request_comms/` are on), so no customer receives a line from it. Owners per part:
  `docs/support/caroline-monitor.md` §"What sends the message back".
- **A fix is recorded per SHAPE in `policies/caroline-shapes.json`, never per conversation**, and is re-measured
  against the other shapes once its row has `shipped_at`. A new bot admin or a staffed team inbox goes in
  `monitor.non_human_admin_ids` / `monitor.staffed_team_ids`, or its assignments are misread.
- **Changing a rule = bump `RULES_VERSION`, re-label (`calibrate sample` / `score`), re-record the baseline.**
  `scripts/check-caroline-shapes.py` fails CI while the hand labels on file are for older rules.
- **A commitment's owner is a job, rule or tool, never a person, and there is no close call**: the ledger row is
  rewritten only from a new read of the thread, so only a message sent on that conversation closes it.
- **It sends nothing.** The sender is `scripts/request_comms/` (still off: `enabled: false`), which asks the
  ledger which thread carries the promise. Turning those lines on is a captain decision on the exact copy.
- `waiting_on_us` is 1,554 with 1,394 older than 90 days, so never alarm on `> 0`; use `waiting_on_us_by_wait`.

## A customer waiting on a person is paged, and a bot hand-off is not an answer

`scripts/intercom-unanswered-reply-watchdog.py` (hourly `intercom-unanswered-reply-watchdog.timer`,
read-only, no model) pages `#cs_priority`, paid first, for open Intercom threads waiting 24 h+ on a
person. Doc: `docs/support/unanswered-reply-watchdog.md`.

- **"Did the customer write last?" is the wrong question.** The thread it was built for ended on
  Caroline saying "I'm pulling in a teammate", twice, with no person for 13 days. Only a HUMAN admin
  reply keeps a hand-off promise; her later replies never restart that clock. Decide from the thread,
  never from `statistics.last_admin_reply_at` alone (1,705 by statistics vs 607 on reading, 11-11).
- **Never close a conversation to make the count fall.** A thread that leaves the open set while
  owed is re-read and reported as "closed without an answer".
- Paid is the house paying list (`decide.paying_users()`); no usable list, or a list only partly
  mapped to Intercom identities, makes every unmatched thread **paid status unverified**, never
  free (it is listed and repaged on the paid cadence).
- **It is not `caroline_monitor/`.** That job pages `#clio_devops` on a WEEKLY aggregate that
  regressed (hand-offs with nobody assigned); it never names a thread, so a customer can wait
  forever with its numbers looking fine. This one decides per thread who is owed an answer RIGHT
  NOW. The other Intercom checks (`intercom-backlog/count.py`, `cs-needs-human-digest.py`,
  `cs-sla-report.py`, `reply_due_scan.py`) count or report; they do not page.

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
never reloads the gateway onto an unreviewed shell posture), plus a tick in `cron-health-watchdog.sh` so an exception
that runs out during a deploy-free week is noticed.

**An expired posture resolves to DENIED, never to "carry on" — and the clock now runs a week early.** A dated `full`
exception is valid THROUGH its date; the day after, the checker fails and the deploy halts at Step 1 (2026-11-09: that
is how a burned deploy happened, with PR CI red fleet-wide for every lane until the postures were settled). So the
tick runs `check-agent-exec-policy.py --live --fail-on-expiring`, which returns **rc 4 = "clean, but a dated exception
is inside its 7-day window"**, and pages a WARNING naming the **expiry date and the countdown** rather than the
violation wording. Inside the window the row no longer prints `full until <date>` — a row about to lapse must not read
as clean. Deploy and PR CI leave the flag off on purpose (an approaching expiry must never block the deploy that
carries the fix) and stay rc 0 until the date actually passes. **A renewal is a ruling, not a data edit**: the base
rule rejects a RE-GRANT to a non-ops agent, so restoring `full` needs a reviewed change to the checker's rules. The
tick dedupes per FINDING (the stamp
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
(legal hold 1350): both wrapper copies and `scripts/muso-prewrite-hook.sh` refuse that route as a removal
(`MUSO_REMOVAL_NO_SELF_APPROVE`). Customer sends stay locked until Fable's GO lands in a PR.
A track / album passes only through its ONE catalog artist's profile on the same paths (`identity.decide_item`).
A claim ties a requester to a page only when it was processed after it was made AND one of its verification links
names that page's own Spotify / Apple artist id or one of its linked social accounts (`sources.link_matches_profile`,
applied in `sources.page_facts`; rulings 2026-11-13 and 2026-11-14; a website host or any other page-shaped link
is not a match, and a profile that cannot be read matches nothing): 5,226 of the 5,798 claims processed in 30 days
are filed by the account and processed the same instant. It still cannot measure WHO put the links on the profile.
The hide batch reads the STORED verdict, so a rule that narrows a pass raises `identity.RULES_V` (now 3): an older
pass is not hide-eligible, and while one is on file `hide-batch` touches no PR. An already-hidden page keeps
`ALREADY_HIDDEN` on a re-decision: never un-hidden, never planned again.
A requester whose own claim lacks that evidence gets the ownership ask (`dsar.NEED_CLAIM_EVIDENCE`: a matching link or a
label / management document, never an identity document), sent at once and once; `ownership_ask_at` records when and
moves no date. No code reads the reply yet: it is a person's to read.
Each repo has one live batch PR carrying the whole set; a changed set opens a new PR and closes the old one, never a
force-push. What Caroline answers, does and hands off for billing and hides, the refund caps and every undo:
`docs/support/caroline-billing-and-hide.md` (pinned by `policies/caroline-billing-and-hide.json` + its test).

**No page reaches a hide PR without the hide guard** (`scripts/gdpr_pipeline/hide_guard.py`, captain 2026-11-13;
`docs/support/gdpr-pipeline.md` §"The hide guard"; audit `data/gdpr-takedown-ownership-f3/report.md`). It re-reads
the requester's claim from core at batch time and holds a name match and a legal request with no ownership, on
`--include-legal` too; a legal threat from the account that holds the claim is decided on path A, like any owner
request. A row in the planned batch whose recorded pass the guard no longer admits is decided again first, so the
identity step asks the requester instead of the page waiting behind a hold. The 24-hour hide page reads the guard's
own last decision: a held or not-yet-judged page is never reported as "open/merge the hide batch PR", and a message
made only of those lines names no person. Three things to keep:
- **A processed claim is not ownership by itself.** It counts when it was reviewed (empty `reason` and a
  verification link that matches the profile, by the identity step's own `sources.link_matches_profile`, read
  again against the live profile at batch time, on a claim processed after it was made) or sits on the one muso-source profile that account created. `Run.decide_row` applies the same
  rule (`hide_guard.prove`), so an unproven claim is an `ASK_IDENTITY`, never a pass and never a silent hold.
- **3 profiles per requester and 20 across the register per 24 h**; the rest are held, paged once and offered again.
  Raising either constant is a captain decision, not a tuning change.
- **A proof that cannot be read stops the run (exit 2) before the open PR is touched.** Read the profile's sources
  from the admin profile, never `matvw_catalog_profile`: it was four days behind and lacked the newest profiles.

**A statutory request (erasure, access) is handled by the DSAR ladder, never routed to a person** (captain
2026-11-12; `scripts/gdpr_pipeline/dsar.py`, `docs/support/gdpr-pipeline.md` §"The DSAR ladder"). Three rules are code:
- **No verdict, no send.** An acknowledgement or status update reaches a writer only when
  `scripts/outbound_copy/gate.py` approves its exact bytes under the `gdpr` rubric
  (`gdpr_pipeline/copy_gate.py`, called inside `send.deliver`). A missing, pending, refused or unrunnable gate is a
  hold. Never add a flag, env var or second path that sends a ladder kind without it. The bytes asked about are
  the letter on the wire (`send.reviewed_form`): a notices@ / legal@ deletion request is answered in a new thread,
  so its approved opening line and subject are reviewed with the body, and rule 8 of the rubric names them. One
  customer message per person per UTC day (`store.person_contacted_on`, the Art. 15 answer included); the held one
  goes the next day. A day-held Art. 15 answer is a recorded debt on the row (`access_owed_at`) that the tick
  delivers before any ladder letter, rebuilding the copy first when it is past `access.FRESH_HOURS`.
- **Identity is claim or authority, never a name and never a passport.** A name match is not a tie to a page
  (`identity.decide_page` paths B/C answer `ASK_IDENTITY`); no copy asks for an identity document (Art. 12(6)).
- **The body carries dates only.** `policies/gdpr-dsar-copy.json` is fixed text per variant; code fills
  `{received}`, `{due}`, `{next}`. A name or link in a ladder body breaks the reason its text may be reviewed off
  node-8. `denial` and `extension_complexity` are locked (`enabled: false`); `extension_number` is sent only on a need
  recorded with its ruling (`dsar extend`), for 2+ open requests from one requester, while the date is still ahead
  and code cannot send the answer: a count of requests is a ground, not a need. Never to cover lateness.
The clock (`dsar clock`) names every request inside 7 d of its date, and every one nobody has written to after
48 h. The first message is due 24 h after arrival (`dsar.FIRST_REPLY_HOURS`; `first_reply_overdue` in the clock
JSON, and each `dsar_sent` event records when it was due and when it went). A statutory row is owed nothing until it
has `gates.v`, so a tick decides a chainless one at once, a failed identity read writes an `unknown` chain
(`Run.chain_unread`), and a row closed with no final response is reopened (`Run.reopen_unanswered`).
`gdpr-dsar-clock.timer` reads it hourly on node-8; firstmate's check
`scripts/gdpr-dsar-clock-check.sh` pulls it (node-8 has no route to firstmate), and
`scripts/gdpr-dsar-clock-register.sh` is what puts it in a firstmate home (`--check` asks whether a home has these
bytes). The unit pages when no check has read the clock for 26 h, or the one reading it is not the deployed one
(`dsar.clock_unread`): run the register script again whenever the check changes.
The older ask stands down only where the gate holds a letter for THAT request: `dsar.OLDER_ASK_STANDS_DOWN` has one
row per gate verdict (sent, approved, pending for 24 h at most; refused, error, missing and none proceed) and a
test per row. An ask's WORDS are refused separately and on the record (`run.ask_refusal`), never by leaving a row
off the list. The register stores `''`, never NULL, for an unset timestamp: `confirmed_at IS NULL` matches no row.
A row stamp is not the record of a send: 23 open rows had a `sent` ask and 7 a `sent` final confirmation in
`erasure_sends` with no stamp on the row, so "was contacted" and "was answered" read the ledger too
(`dsar.contacted_at`, `dsar.final_response_at`). No message states an answer date code cannot keep
(`run.answerable_now`).
An erasure request whose every page is already off the site, or hidden on some pages and gone on the rest, gets the
`final` letter, and only on a read of each page made in the same run (`Run.gone_now`: a gone page deleted, not
merged, public 404; a hidden page 410); an unread page owes nothing that run. The hidden-and-gone letter states
the two facts and no address message for either group: two different messages tell a reader which page is which,
and the reviewer sent that wording back twice.
A ladder letter may open a new thread to a support requester with an address and no thread
(`send.LADDER_NEW_THREAD_CHANNELS`), and one customer event on two open rows gets each letter from one row only
(`Store.event_twin_send`); once one row holds the final answer the other is closed as its `duplicate`
(`Run.close_answered_twins`).
A past-date statutory request with nobody to write to is `closed_unreachable` (`Run.close_unreachable`): the clock
lists it, never as answered, and `Store.upsert` reopens it when a message brings a route. It closes only on a settled
verdict and only with what it is owed measured that run (a gone or hidden-plus-gone row whose read was unknown waits).
Never write that status by hand on a row with a page still to hide: the hide batch reads open rows only, and
`hide_due_rows` is what keeps watching the pages such a row had already hidden. Any reader that filters on
`status == "open"` skips these rows; one that must see them asks for the status by name.
Details: `docs/support/gdpr-pipeline.md` §"The final answer for a page already off the site".
The Art. 15 copy (`gdpr_pipeline/access.py`, manifest `policies/gdpr-access-sources.json`) is built for the account
the requester controls and sent only when COMPLETE, to the address on the account; an incomplete copy names its gaps
and is never the answer. Only counts and hashes of a copy may reach a log, the trail or stdout.
**A staff "hide this profile" ask is `scripts/ops_intake/hide.py`, and the soft-delete is refused at BOTH write
surfaces.** Between 2026-10-22 and 11-04 the operations bot ran `muso … api DELETE /admin/profile/<id>` 24 times on
a staff member's word (a workspace-only skill nobody reviewed as policy): each call tombstoned the profile AND every credit
served on it (one profile went 431 credits -> 0; the 23 ids that had credits hold 717 of them on their
admin tombstones and ZERO served associations today), with no list entry and no inverse. Both wrappers now refuse that endpoint (`MUSO_REMOVAL_NO_SELF_APPROVE` in `muso-admin-api.sh`, the same gate
in `scripts/muso-prewrite-hook.sh` for every `muso` CLI caller), the skill is deleted. The ask intake files the register row, lets the
pipeline decide identity, and prepares the reversible PR pair; `/cache` and the `/credits`/`/member`
sub-resources are NOT the soft-delete and stay allowed. Evidence + the credit-restore question: "data/gdpr-tombstone-repair-21/repair-21.md".

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
  bats test. **The marker is a map of `path -> last-loaded-at`, not a timestamp and not one slot**: a
  `--registry` scratch run (a QA review tree, a fixture) must never vouch for the live path, and must
  never evict it either — `registry.REGISTRY_DEFAULT` is pinned outside the 20-entry cap, because the
  live path is the one whose loss actually blinds us. Both mistakes shipped and both paged
  `#clio_devops` hourly about a registry nobody had deployed (#1838).
- **Ticks serialize on a host `flock`** across load → evaluate → save → mirror PR; a tick that cannot
  acquire within `SENTINEL_LOCK_TIMEOUT` exits 0 silently (the other tick is doing the same join).

## The proof path: one feeder, one reader, one marker, one reviewer, and no armed decision

A customer's document goes file -> read -> decide -> mark -> review -> tell, one owner per stage:
`docs/credit-verification/proof-path.md` (what each named processor is, what retires and its replacement).
Counts: `data/proof-processing-ovh-e1/tools/measure.py` on node-8.

- **The feeder is `credit-proof.py file-recent` and it saves as it goes.** The search result goes into the state
  before any conversation is read, conversations are filed 25 at a time with a save after each, and a run stops
  itself at `--max-seconds` (2400), under the cron's 3000 s kill. Saved only at the end, one 24 h kill-file pause
  froze the cursor for 67 hours: 36 of 37 runs failed with nothing saved. **A job whose progress is saved only on
  success has a backlog size past which it never succeeds again.** Read a cron's health from the gateway's
  `cron_run_receipts`, not from its exit-0 "another run is in flight" lines.
- **"Did they answer" is `verify_messages.proof_tagged_at`, set by `credit_review/proof_marker.py` from
  `proof_intake`** (a document dated after the note, filed against one of the note's requests; any document for
  a claim note). It never judges, sends or approves, every tag is a `proof_marks` row, and
  `revert --run-id` undoes a run. The Intercom tag sweep (`verify_notify.sweep_proofs`) never recorded a look in
  production; do not wire a second writer. **A tag is three writes, not one, and `verify_ledger.mark_tagged` is
  the reference**: the family (`id=root OR parent_row=root`), the attachment count, and the rejected verdicts of
  every family `verify_ledger.proof_families` names (a credit's verdict lives under the note it was first asked
  on). The first marker tagged one row and cleared one family; `test_it_leaves_the_ledger_as_mark_tagged_does`
  now holds the two writers to the same ledger. A review suppresses the tag only for the credits it was recorded
  against (`verify_proof_reviews.request_id`, under that credit's own note): a review of another credit, or on
  another note, never leaves an answered note untagged. It leaves `conversation_id` alone: empty there means
  "sent by email".
- **Proof review is `credit_review/proof_reviewer.py`, never a person** (captain 2026-11-13). It writes
  `verify_proof_reviews` from doc-verify's recorded outcome (`reviewed_by` names the rule, the doc-verify
  version and the model), sends nothing and approves nothing in core. A document doc-verify has not read, or
  read only as `unknown`, gets no verdict at any age: the credit stays under review waiting on our reader
  (every run's output carries `wait_reader` and `wait_reader_oldest_days`), never on a person and never removal-due; `credit-review.py --proof-review` is an ops
  override. The cron is armed (2026-11-15). An `apply` that reached verdicts and left no row on file exits 70:
  with the cron off, 662 marked notes had 0 reviews and nothing failed.
- **A tag is not a decision.** No job turns a read document into a core decision: the document class is
  `approved: false` in `policies/credit-approval-automation.json`, `doc_approvals` is empty and core's
  `credit_document_verdicts` has 0 rows. Report the stages separately (filed, read, answered, decided, told);
  never report "proof processed" from the first three.
- **Stage 2 judges only what the decider holds as `proof on file`** (`stage2.held_rows`), and the decider lists
  `unverified` only. Documented requests already in `user_verification_needed` reach stage 2 through
  `decide.hold_documented_uvn` (ledger rows only, capped per run) - the mechanism, its caps and its run-line
  fields are owned by `docs/credit-verification/credit-trust-decide.md`; before it, 2,568 documented users
  had no verdict path and the uvn-status lists held them forever
  (`data/send-families-zero-sends-r1/report.md`).
  A list that reads thousands and messages 0 is a list question first: attribute the drops per gate from the
  tick's `-check.json` before touching a gate.
- A ledger table that only one tool reads is created by that tool, never added to `verify_ledger.SCHEMA`: every
  read-only reader refuses a ledger that lacks a table `connect()` would add.

## The verification scale drain: one deterministic ladder, one reviewed ask path

The 92,861-request verification backlog is a **one-time drain**, not a throughput problem:
at 1,000/min it is 93 minutes, then a small continuous tail. Design of record is
`data/verification-scale-plan.md`; the operator doc is
`docs/credit-verification/scale-drain.md`. The measured ceiling was 1.4 min/user because
`muso-admin-api.sh` did three round trips per user (token resolve, account resolve, route).

- **`scripts/credit_review/scale_drain.py`** is the decider: a single SQL ladder
  (`LADDER_SQL`) in rank order — a duplicate the ladder cannot resolve → `unmatched`; precedent →
  approve on a per-claimant prior approval, or `cannot_confirm` on a refuse precedent
  that nothing on file postdates; a
  readable proof verdict → approve, or ask on a refuse; **asked** and expired with no
  proof → `cannot_confirm`; else ask. **No model in the hot path** (Aaron's 2026-10-29
  ruling: a model reviews a sample and proposes rule changes, it never decides a row).
  `decision_key = sha256(request_id || rule || outcome || version)` is the ledger primary
  key, so a re-run cannot double-apply and a killed worker re-reads its shard and skips
  every row already in the ledger (there is no cursor to lose or trust). The **outcome** is
  in the key on purpose: without it a decision that changes keeps its key and `apply` skips
  it, so a row recorded as `cannot_confirm` that later becomes an approval would be
  silently dropped. The plan JSONL is canonical (sorted, no clock, no run id) — that is
  what makes "run it twice, diff the bytes" a real test.
- **An expiry may only reach a request we actually ASKED** (`asked_at IS NOT NULL`). A
  never-asked request falls through to `ask`: the 23,247 OPEN_UNASKED rows are the
  drain's population, not its expiry pile, and an expiry is the record of a window the
  customer was given and did not answer (captain decision 2026-11-11).
- **`apply` performs a real API side effect** through the one reviewed path
  `muso-admin-api.sh` already exposes: `PUT /admin/credit-requests
  {"requestIds":[…],"status":…}` through the wrapper, so the full gate chain still runs.
  `approve` → `approved` and no other status (`WRITE_STATUS`),
  `ask` → no write (the send is `need_asks.py`'s), `cannot_confirm` → no write and no
  message. **Intent, write, confirm**: `apply` commits an `intents` row BEFORE
  the API call and confirms it after. An intent left open (a kill between the two, or a
  write that failed or timed out) is never retried blind: the next run reads the live
  request (`verify_anchor.reconcile`) and records `reconciled`, retries a still-pending
  one through the gate, or abandons with a reason code. The gate still refuses a decided
  request; write-then-commit could not recover that row at all (QA review 5).
- **The approve bucket has never landed, and it lands only through core's `precedent`
  scope.** 0 of the 3,326 approve intents are written (measured 2026-11-13): core answered
  HTTP 400 `agent_cannot_approve_declined` because the drain was no registered automation.
  Ruled A the same day: core-backend #11378 / #11379 register `verification-scale-drain`
  on its own account `agent-scale-drain@muso.ai`; core finds the precedent itself and
  admits about 400 of the 3,326 (the rest need the claimant's proof or fail the scope).
  An approve sets `MUSO_ADMIN_IDENTITY=scale-drain` and the operations wrapper sends
  `X-Credit-Automation-Id: verification-scale-drain`. It writes nothing until the core
  PRs are deployed, the account holds the `credit-automation` role, and
  `/etc/openclaw/agents/scale-drain.env` is on node-8. Never borrow another automation's
  account or header. `apply` records each failed write with its layer and core's reasons
  (`write_failures`, `scale_drain.py failures`), holds a refused row instead of re-sending
  it (`--redrive-refused N`), stops after 10 failures in a row, bounds a batch with
  `--max-writes`, and confirms an approval only after reading the request back. A
  retryable or session status (401/403/408/425/429) is never held as a refusal.
- **A refused approval is never left as `approve`.** `core_row_refused` is recorded in the
  append-only `core_refusals` table as `refused_by_core:<reason>`, and the reason routes it:
  `proof_required` / `no_sound_precedent` go to the ask path (`refused_to_ask`, emitted by
  `asks --plan P --out FILE` for `need_asks.py build --from-drain`, the one reviewed ask
  path), any unnamed reason stays held. Beside an ask reason, `validator_hold` is asked
  too UNLESS the hold is one no document clears (`hold_blocks_ask`). **On this refusal
  route, a cause no document clears is never asked, alone or under an askable hold, and
  with or without core's `validator_hold`** (`never_asked_cause`): a hard cause
  (`HARD_HOLD_CAUSES`, `_hold_on_error` included), any band C cause of the table
  (`validation_error` and `_no_signal` included), a velocity cause outside an editing
  burst or with unreadable roles, and a band table that cannot be read
  (`bands_table_unreadable`, which holds claim-proof-ask too, by user).
  `hold_causes` not read from the snapshot (`hold_cause_unmeasured`), a snapshot with
  no cause (`hold_cause_not_in_snapshot`) and a cause in no list
  (`unclassified:<cause>`) hold only beside `validator_hold`; where
  core lists no `validator_hold` those rows are asked. The band list itself is `band_c_rules` +
  `band_c_error_keys` of `credit_trust_bands.json`, read at run time and never copied
  (plus `fraud_hold`), found wherever the verdict records it (`rule_risk_percent`,
  `rule_errors`, `hold_reason_codes`). Core says `validator_hold` only for `review_*` at 30
  or more, so a `reject_*` rule arrives with no word from core. A velocity rule is the
  bands' band B only on an editing burst (`editing_burst` on the plan row, from the bands'
  `high_risk_roles`); every other velocity hold is band C and stays held. Core never
  says which hold it is, so the cause comes from the snapshot (`hold_causes` on the plan
  row): a plan made before that field existed, and a plan from an earlier version of this
  code that carries `hold_causes` built from core's reading alone, both miss every band C
  cause - build a new snapshot and plan after this deploys, before any apply - and "on the ask
  route" is not "asked" -
  `need_asks.py` sends only where a document names a sendable need. The route has one source, the
  recorded `core_refusals` row, so a refusal whose route could not be recorded is held and
  never reported as waiting on an ask. No tier-2 or person queue for a refused approval,
  the run that meets those refusals is not an error (`held_by_core`, `errors` 0, exit 0),
  and a held row is never an incomplete run: `apply` exits 0 with the held counts printed.
- **No ask names a request held for a cause no document clears, in ANY sender** (owner
  2026-11-14: "fraud or impersonation means no ask, ever"). The reading is ONE function,
  `credit_review/policy.never_ask(verdict, claimed_roles)`; `scale_drain` re-exports it and
  no sender restates it. Where it is applied: the drain's refusal route (above) and its
  ladder `ask` rows (`asks --plan` drops them, `held_never_asked`); `uvn_status` for every
  ask campaign (`NEVER_ASKED` in `NO_ASK`, so uvn-status, gap-ask and uvn-new-rows leave
  the request out, and it outranks the proof-required override); `need_asks.build` AND its
  send-time read (`skip_never_asked`); `claim_proof_ask` first notes and reminders, by
  USER (`uvn_status.never_ever_users`: fraud and impersonation because a claim
  carries no credit verdict, plus an unreadable band table, which holds everyone; it reads
  `unverified` requests too, where 2,303 of the 3,443 flagged requests sat on
  2026-11-14). The answer names ONE cause and fraud, then impersonation, is named before
  any other on the row: the account hold reads that one class, so a `reject_*` rule that
  sorts first must never be the one named. A held request is not locked or closed: it is
  read again each run.
  Status notes (`status-*`, `claim-status`) are not asks and are unchanged.
  `doc-result` has no sender in this repo: its 37 messages of 2026-11-11 came from a
  one-off script on node-8 that reads none of this. A new ask sender calls
  `policy.never_ask` and gets a test; why this exists: 26 of 480 impersonation-flagged
  users were sent a verify message 10-14 November, 22 of them by uvn-status.
- **The pass is small, and an `ask` is not a decision.** Measured on the live snapshot
  2026-11-11: 3,294 approve, 1,324 under the since-removed `queue_tier2`, 856
  `already_on_profile` (unmatched), 91,229 ask of 96,703. Never describe it as deciding
  the backlog; the table and the reasons two rules are zero are in the operator doc.
- **The proof store keys a verdict by CLAIM (`<request uuid>#<Role>`), and core's
  `duplicate_of` is a map of credits, not a request id.** Keyed by bare request id the
  proof rule matched none of 326,611 verdicts, and the map crashed the plan. A document
  on file with no decisive verdict keeps `proof_received_at`, so it is
  `ask`/`proof_on_file_undecided` and never `expired_no_proof`. Run a ladder change
  against a real snapshot before believing a fixture.
- **The drain writes `approved` and nothing else; no outcome is a person** (captain
  2026-11-14). There is no duplicate close: core sends its rejection notice on every move
  to `rejected` and refuses `notify: false` on it, and `DECIDED_SQL` reads a `rejected`
  row back as the claimant's refusal of the claim, dated the day of the close. A request
  that names a decided original is decided by precedent like any other; `apply` refuses a
  plan that still carries `close_duplicate` (`RETIRED_OUTCOMES`), and neither wrapper
  has a drain exception to the reject gate. Never add a drain write of `rejected`. The ladder no longer emits
  `queue_tier2`: expired-with-no-proof and a refuse precedent are `cannot_confirm`, a
  refuse proof verdict is `ask`, and `tier2-queue` lists no row. **`cannot_confirm` is
  interim and is not a decision**: a ledger row, no write, no message. The request stays
  pending and the next plan decides it again. **A refuse precedent is not final**
  (`SET_ASIDE_SQL`): evidence newer than the refusal (`requests.evidence_at`: a filed
  document, a `built`/`written` DSP anchor or a proof verdict, against
  `precedent.decided_at`, core's `updatedat`) takes the request out of the rule, and an
  unmeasured refusal time does not stand over evidence. Nothing tells the customer that,
  so never count a `cannot_confirm` row as decided or told (994 of 1,172 refuse-precedent
  rows had nothing newer on file, 2026-11-15). The 1,324 `queue_tier2` rows of 2026-11-11
  are still in `applied`, each with a `told` row that no message backs. Never lower a
  served number.
- **The drain never sets `CV_APPROVE_GATE_DISABLED`.** That variable skips every evidence
  requirement and must not be set by an agent. The wrapper instead carries a fifth
  registered predicate, `is_scale_drain_approval`, which admits only
  `scale-drain@hydra-ops` + `SCALE_DRAIN=1` + the drain's token + the registry entry + a
  body of exactly one request id + an `EVIDENCE_EXCERPT` matching
  `drain-signal:<rule>;<reason>;v<n>;(<uuid>|<64-hex proof id>);<profile|->`. The digest
  must name an auto-approvable rule AND a row-specific anchor (the precedent request, or
  the proof id — a proof id is a sha256 digest, not a UUID). **A digest is a claim, not a
  fact**: the predicate hands the parts to `scripts/credit_review/verify_anchor.py`, which
  checks the anchor against a source the caller does not control — one admin GET for the
  claimant's profile (the anchor must be `approved` and match on claimant, track and
  roles) for `precedent`, or the root-owned proof store plus the same one GET for
  `proof_verdict` (the newest verdict of every claim **for the request** must be a
  decision on the anchored proof, and **every role the LIVE request claims needs its own
  verdict** - a check that walks only the store approves on whatever happens to be on
  file). A verifier that cannot run refuses the write. **An approve
  carries exactly ONE request id**: one digest names one anchor, so a second id is a write
  nothing verified. **It presents the token**
  (`/etc/hydra/scale-drain.token`, mode 600, owned by the drain's own user; one check,
  `scale_drain_token_ok`). It raises the bar to "can read that file" and is not claimed to
  be non-forgeable - any root process on node-8 can read it - and **nothing creates it**:
  until an operator places the file, `apply` refuses every write. The verified anchor is
  what makes an approval per-row true. A row with no anchor is **not**
  downgraded to an ask: it is `unmatched` (`unmatched_precedent` /
  `unmatched_proof_verdict`), counted and never written, so a user who was already
  decided is never sent a fresh "please verify" ask. `scripts/check-credit-approval-automation.sh`
  enumerates the wrapper's `is_*_approval` predicates — in all three Bash spellings
  (`name()`, `name ()`, `function name()`) — and fails CI when one has no registry entry
  naming it in `wrapper_predicate`, so a new approve path cannot ship unregistered.
- **The bulk read is the core replica, not the admin list.** The admin list refuses
  unfiltered paging past offset 20,000 and its own refusal text says to use Trino; 92,861
  rows at `limit=200` is page 465. `snapshot` reads
  `postgresql_core.public.credit_requests` in one query and joins the verify ledger for
  ask history (core has no `asked_at`; only ASK campaigns count, and it is keyed by
  **request** from `request_ids_json`, not by account — keyed by account, an old unasked
  request could be expired because a different request for the same user was asked). The
  admin API is the
  write path.
- **hydra's gate is half of an approve; core keeps its own register, and `apply` needs the
  admin env.** The registry entry and `/etc/hydra/scale-drain.token` only satisfy the
  wrapper's gate. core approves a validator-declined row only for an automation in ITS
  table, bound to the logged-in account and named in `X-Credit-Automation-Id`. Read the
  refusal's REASONS, not its code: `no_registered_automation` is
  `core_automation_not_registered` (a registration in core, never a retry); any other
  reason is `core_row_refused` (core judged the row; held, and not counted by the
  breaker). `apply` also preflights the admin env, and the approve's identity file,
  before it records an intent and counts every failure by cause (`error_classes`). Causes, and what
  a caller can do about each: `docs/credit-verification/scale-drain.md` §"What `apply`
  needs".
- **`scripts/credit_review/batch_admin.py`** is the hoist: `muso-admin-api.sh call-batch`
  is ONE process, ONE token resolve, N requests, with the same gate chain `call` runs.
  Never add a direct-HTTP batch client — it would bypass the approve/reject/removal/
  tier-2/pace/merge-reverse/enrich-link/bulk-destructive gates. The route call is NOT in
  the decision path: the sender is the tail.
- **There is exactly ONE reviewed ask/notify path, and it is `need_asks.py`.** The drain
  decides WHO is asked - the ladder's `ask` rows plus the rows core refused back onto the
  ask path, emitted together by `scale_drain.py asks --plan PLAN --out FILE`;
  `need_asks.py build --from-drain AUDIENCE` takes that
  audience and still decides WHICH document and owns the send through
  `intercom-verify-request.sh --campaign proof-need-ask`, and `credit-approved-elsewhere` (the conflict rule's
  stamped rows, send-locked). This is the reconciliation with
  verify-ask-wiring-h2 (PR #1845). A drain ask with no sendable document is listed as
  `wait:no_sendable_document` with a `due_at`, never dropped. Do not grow a second sender.
- `expires_at` does not exist in core; the snapshot derives it from **`asked_at`** +
  `ASK_WINDOW_DAYS` (30), keeps a core-supplied value when one appears, and leaves it NULL
  for a never-asked row. Keyed on `created_at` it expired a request the moment we finally
  asked it (created 2026-01-01, asked 2026-11-10, refused 2026-11-11) — a denial of a
  request the customer was never given time to answer (QA review 3 of hydra#1883).
- **`chaos` takes no `--ledger`.** It makes its own scratch SQLite in a fresh temp dir.
  Refusing only the default path or a non-empty ledger was not enough: a fresh custom
  ledger a real run was about to use got filled with no-writer `applied` rows, and the
  real run then skipped them.
- **Neither the verifier's path nor the proof store is caller-controlled.** `HYDRA_ROOT`
  and `CREDIT_PROOF_STORE` are env vars, so a caller could point the check at a substitute
  verifier or a SQLite file it wrote itself. The wrapper derives the verifier from its own
  location (`scale_drain_root()` walks up from `$(dirname "${BASH_SOURCE[0]}")` to
  `scripts/credit_review/verify_anchor.py`) and the proof store is a constant in the
  verifier. The walk starts from the wrapper's `realpath`, so a symlink to the wrapper in
  a caller's tree still trusts the deployed tree. **The approval registry is pinned the
  same way** (`scale_drain_registry()` → `<root>/policies/credit-approval-automation.json`);
  a `CREDIT_APPROVAL_REGISTRY` or `HYDRA_ROOT` resolving to another file is refused (QA
  review 5: a caller's own `approved: true` registry was honoured). The older predicates
  in the operations wrapper still read that variable.
- **The gate's trust sources are pinned, and an override is REFUSED, not ignored** (QA
  review 4 of hydra#1883). The verifier reads the admin API only through the operations
  wrapper found from its own location (`verify_anchor.ADMIN_SCRIPT`); a
  `CREDIT_REVIEW_ADMIN_SCRIPT` resolving elsewhere fails the write. The token
  path is the literal `/etc/hydra/scale-drain.token`; a set `SCALE_DRAIN_TOKEN_FILE`
  fails the write. Never add an env or CLI seam for either - a positive test rewrites the
  literal in a scratch copy. **Every new trust source is a hole until it is pinned to
  something the caller does not control**: four were found in review, one at a time
  (verifier path, admin script, token file, registry). What a bash gate cannot pin is the
  caller's whole environment (`PATH`, `BASH_ENV`, the API URL and credentials).
- **The wrapper runs the verifier as a FILE (`python3 -I verify_anchor.py`), so it must
  not use a relative or `sys.path` import.** `from . import batch_admin` made both gates
  refuse every write while 113 tests passed, because none executed the real entrypoint.
  `RealEntrypointTests` runs `bash <wrapper>` at its real path with only `curl` stubbed;
  a gate change that is not exercised there is not tested. Since a passing write needs the
  root-only token, its passing cases run in a byte-for-byte mirror of the tree with that
  one literal rewritten (a test holds the mirror to the diff), and the checked-in files
  are run unmodified for the refusals.
- Tests: `scripts/tests/test_scale_drain.py` (ladder, idempotency, shards, byte-identical
  re-runs, kill -9 chaos), `scripts/tests/test_verify_anchor.py` (the anchor checks:
  unapproved anchor, different claimant/track/roles, newest-soft-verdict-wins, unreadable
  store is a refusal), `scripts/tests/muso-admin-api-scale-drain-gate.bats` (both wrapper
  copies: digest shape, delegation to the verifier, missing verifier refuses, batch body
  refuses, the pinned token path, a drain `rejected` refused by the reject gate) and `scripts/tests/muso-admin-api-call-batch.bats` (one
  token resolve, per-item failure isolation, writes serialised after reads, gates still
  run).

## The established-claimant rule records a decision in shadow, and approves nothing

`scripts/credit_review/established_claimant.py` (policy `policies/established-claimant.json`, doc and the
production count `docs/credit-verification/established-claimant.md`) reads the core replica and writes
`decisions.jsonl` + `funnel.json`. It has no writer and no registry row. `established-claimant.timer` runs it once a
day (03:20 UTC) and publishes to `/var/lib/hydra/established-claimant/latest`. A request is established when
its profile has 100+ approved and 1% or less rejected and the same user holds an approved credit in every claimed
role with an artist of the same track.

- **Approve only where the validator's own verdict approved** (`is_approved is True`). A validator-declined request
  is an `ask`, never an approval (captain 2026-10-26); a record of any size does not change that.
- **A hold is honoured for everyone.** The reading is `policy.never_ask`, not a second list: a hold no document
  clears is `barred` and nobody is asked; a hold a document clears is an `ask`.
- **Unmeasured approves nothing**: no verdict, an unreadable part or a verdict row the replica did not return is
  `barred` or a failed run (exit 1), never a pass.
- **Core's guard would refuse all 2,078 measured approves** (`proof_required`; `core_guard` on each row). Arming it
  is a new approval automation: a recorded captain decision, a registry row, a registration in core and a write
  gate that re-reads each row. The policy file's `mode` accepts `shadow` only.
- **A pass publishes whole or not at all.** A read that did not finish publishes nothing, fails the unit (which
  pages) and leaves `latest` on the last complete pass. The stop switch `/etc/hydra/established-claimant.disabled`
  ships absent: nothing has to be removed for the next pass to run.
- The reads are five statements, 200 ids each, no self-join. The unit is capped at 2 GB; a scratch `run --out DIR`
  goes under `systemd-run --scope -p MemoryMax=2G`.

## A replica question costs ~2 s whatever it asks: ask once per person

A `trino-query.sh` call is ~2 s of fixed cost (`kubectl get pods`, `kubectl exec`, the CLI's JVM); `SELECT 1` costs
1.85 s. On 2026-11-12 the send gate asked 5-6 questions per person, 10 s of a 13 s call against the 20 s read
timeout, and the timeouts tripped the unmeasured bar (`UNMEASURED STOP`). Doc and numbers:
`docs/credit-verification/gate-replica-read.md`.

- **Never fix a slow gate by raising `READ_TIMEOUT_S` or lowering the unmeasured bar.** Count the round trips
  (`data/node8-fly-gate-v2/tools/proc_sampler.py`) and remove them.
- **The gate takes one read per person** (`credit_review/gate_facts.py` -> `replica_batch.read_many`, one invocation,
  no partial answer) and runs `core_notice.py` / `comm_state.py` unchanged behind `scripts/replica-serve.sh`, which
  answers a statement only on its EXACT text from a read at most 30 s old and runs the real wrapper otherwise. It
  is never a fact source. A read that never answers is abandoned at `replica_batch.BATCH_TIMEOUT_S` (8 s) and that
  wait is spent inside the gate call's 20 s: raising it takes the room a live hold needs (pinned by a test).
- **A new or changed replica statement in `core_notice.py` or `comm_state.py` goes in `gate_facts.py` too**, or it
  is read live (one more round trip per person). `scripts/tests/test_gate_facts.py` fails on the gap.
- A measurement run on node-8 is load on the same replica path the tick uses: run it between ticks.
- **What the replica is asked is what Trino pushes down, not what the SQL says.** A JSON predicate, and a
  `status NOT IN (...)`, stay in Trino: node-19 then sends every row the pushed-down part admits through one
  cursor in one transaction. `EXPLAIN` the statement and read `constraint on [...]`. A read of the held
  `credit_requests` population pages the way `score_approve.candidate_page_sql` does: equality on `status`,
  `ORDER BY createdat LIMIT n` inside a subquery (the table has no `updatedAt` index), the JSON rule as a
  projected column, one statement per page. Still unbounded (2026-11-15): the hourly :07 read at
  `scripts/verification-queue-report.py:579` and its twin in `/opt/muso-sync/ops-completeness` on node-8.
- **Rows read from core or the replica are never committed as evidence**: request, profile and user ids are
  customer data and a later commit does not take them out of history. Commit counts and timings; keep the raw
  files outside the repository and name the path in the PR.

## A writer told "readonly database" was handed SQLite's read-only WAL fallback, not a read-only opener

`attempt to write a readonly database` ended six credit-review ticks on 2026-11-12/13, all as root on a plain
`sqlite3.connect`. The ledger directory is `root:1000 1770` and node-8 has `fs.protected_regular=2`: when the last
writer closes, SQLite deletes the `-wal`/`-shm`, the uid-1000 exporter's read re-creates them as its own, and the
kernel then refuses root's `O_CREAT` open of them in a sticky directory. SQLite falls back to a read-only handle
without an error, reads work, and the first write dies. Root's failed open re-owns the files, so the next run
is fine and nothing is left to see. Repro (two uids, container only):
`data/verif-readonly-write-crash-r1/repro_sticky_shm.py`.

- **`verify_ledger.connect` and `credit_review.ledger.Ledger` open `ledger.sqlite3` through
  `scripts/credit_review/ledger_open.py`** (`open_rw`): it probes the write lock, makes at most 3 opens where a
  reopen can differ, and reports each reopen to `EVENT_SINK` (`credit-review.py` points it at run.log; a caller
  that sets no sink records nothing). A write it cannot make raises `LedgerNotWritableError` with a reason code
  and the owner and mode of each file. This is NOT yet the single write boundary: `open_ledger()` in
  `scripts/credit_verify/dspverify/link_proposal.py` (the enabled hourly `credit-profile-link-proposals` cron),
  `scripts/credit_verify/dspverify/merge_candidates.py` and
  `scripts/credit-stale-velocity-revalidate.py` still write the same `ledger.sqlite3` through a bare
  `sqlite3.connect`, so they can still die with the bare `attempt to write a readonly database` — no reopen, no
  reason code, no run.log line. Routing them through `ledger_open` is separate follow-up work. **A new writer
  must use `ledger_open.open_rw`, never a bare `sqlite3.connect`.**
- **The same opener owns lock contention** (2026-11-15: the intercom drain died on `database is locked` with four
  credit jobs writing): every connection gets a busy timeout of at least 30 s, and a busy / locked statement or commit
  on a write connection is tried 3 times, then raises `LedgerLockedError` naming the tries. `open_rw` never changes
  the journal mode: it reads it into `ledger_journal_mode` and reports a non-WAL ledger. The one-time conversion is
  `python3 scripts/credit_review/ledger_open.py migrate-to-wal <ledger>`, run by hand, never by an opener, a timer or
  a deploy step. Never add a per-caller timeout, WAL pragma or retry loop. A write that never gets the lock takes
  about 91 s to say so. Eight writers still open the ledger with a bare `sqlite3.connect` and get none of this; the
  list, and what the retry does not cure (a read then a write in one deferred transaction: use `BEGIN IMMEDIATE`), is
  `data/ledger-busy-timeout-wal-r1/report.md`.
- **A ledger in WAL mode keeps its contents in the `-wal`, so its main file's bytes are not its contents.** A test or
  tool that copies one copies with `sqlite3`'s backup, and a reader is never held behind a writer: only `connect_ro`'s
  retry window carries a reader past a live migration.
- **A write on `open_ro` / `connect_ro` raises `ReadOnlyConnectionWriteError`** and changes no byte.
- **`READ_ONLY_PROCESS` is set only inside `verify_ledger.read_only_process()`**; never assign it.
- The reopen is a workaround. The cause is the sticky bit plus a reader that creates the WAL files, and changing
  either is a node-8 / H-DevOps decision, not something this code does.

## The bulk send queue: a verdict per person, a durable queue, and it ships unarmed

`scripts/credit_review/bulk_queue.py` (doc `docs/credit-verification/bulk-send-queue.md`, policy
`policies/bulk-send-queue.json`) is the replacement for the per-message apply subprocess that loses its outcomes
past ~80 sends. It is **not wired to production**: the policy is `enabled: false`, no template is pinned, no timer
runs it, and the builder that fills its `people` table does not exist yet.

- **It is a transport, not a second sender or decider.** It writes no copy (every body passes `lib/copy_gate`),
  approves nothing and sends no ask (`need_asks.py` owns asks).
- **The guardrails are triggers, not caller discipline**: no job without a `send` verdict, one job per
  (user, stage) ever, no `sent` without a recorded `attempted`, settled rows and the event log never rewritten.
- **A dead worker's `attempted` row is re-presented only where the provider de-duplicates on our key** (email:
  send-gateway is at-most-once per `idempotency_key`). Anywhere else it becomes `uncertain`, which only a named
  person's `resolve` settles. Never add a route as `idempotent: true` without reading the provider's own code.
- **The send rate is the gateway's warm-up ceiling, not our code**: 2,500 credit emails per UTC day on `notify`
  (H-DevOps `78-send-gateway.yaml` `WARMUP_CEILINGS`), against 6,327 sends/min measured for the queue itself.
  Our chat has no Muso-to-user send, so it carries no batch.
- `bench` and `chaos` take no `--db`, for the reason `scale_drain.py chaos` takes no `--ledger`.
- **Until that queue has an email template for a family, `scripts/credit_review/apply_queue.py` is the TEMPORARY
  queue around the gate call itself**, switched on per campaign in `policies/apply-queue.json` (only
  `claim-proof-ask`; kill file `/etc/hydra/apply-queue.disabled` returns to the direct path). It commits
  `attempted` before `intercom-verify-request.sh` runs and reads each outcome from the **verify ledger**, never
  from the gate's stdout. It changes no cap, audience, copy or tick, and `verify_notify`'s report is identical
  with it on. Add a campaign only after the one before passed `apply_queue.py verify` on its first 100 sends.

## The day-14 verification reminder: one rule, one follow-up, a signed verdict per body

`uvn-reminder-14` (captain 2026-11-13) is the ONE follow-up of a sent uvn-status ask, from day 14. Doc and the
measured audience: `docs/credit-verification/verify-request-notes.md` §"The day-14 reminder",
`data/verif-reask-14d-r1/report.md`.

- **Who may get it is `verify_ledger.reminder14_why` and nothing else** (builder, peek and claim read it). Change the
  rule there; never filter the audience in the tick or the runner.
- **It is one follow-up, not an ask.** Never add it to `ASK_CAMPAIGNS`: `REASK_LOCK_DAYS` stays 90 for every first ask.
- **One reminder per user per ask**: the reminder row's `parent_row` names the ask it follows, and only a live
  reminder of THAT ask closes the user as `already_sent` (a row with no readable reference closes too). `uvn-status`
  asks a user once, so today one-per-ask and one-per-user select the same people; a second ask is not reachable
  through `claim()` today, so the ledger test writes one directly.
- **Never to someone who replied or sent a document**: `comm_state --reminder` holds on any customer message after
  the ask, text included. Do not relax that to the wait line's "a text reply is not replied" rule.
- **It sends only on a signed approve of the exact bytes**, so the first tick after a deploy sends none, and a
  pending body pins the runner's page. Do not move it to `observe`.
- **`policies/credit-verify-outbound.json` on node-8 is edited by hand and by `credit-outbound-watchdog.py` (which
  is not in this repo), and the file carries the delta gate's git-wins marker**, so a deploy of a PR that touches it
  writes the repo copy over the live one without stopping (without the marker the same deploy halts as a conflict).
  Diff the live file against the repo before merging a change to it and carry the live values, or the deploy
  changes caps and arming, a watchdog clamp included.

## The new-rows follow-up: a low cap, a signed verdict per body, and a small audience

`uvn-new-rows` (firstmate 2026-11-14) asks a user we already asked about owed requests no ask named. Doc:
`docs/credit-verification/verify-request-notes.md` §"The new-rows follow-up"; evidence `data/ask-never-asked-r1/report.md`.

- **Its sender lock opened on the copy gate's signed verdict, not a person's sign-off**, and the campaign is
  `enforce`: every body needs its own signed approve, so a tick that renders a new body sends it on a later tick.
- **The class is not the audience.** `verify_ledger.new_rows_user_done` defers every listed user with no SENT
  `uvn-status` ask (1,072 of 1,404 on 2026-11-14): a user core's notice told and we never asked is reached by no
  family. Do not count the builder's `uvn_new_rows` class as people this family will ask.
- **5 users per tick across paid and free** (`NR_CAP` in `scripts/credit-verify-outbound.sh`). Raise it only by a PR
  that cites the first runs' output; never by env, a state file or the policy (`tick_cap` only lowers).

## The ask tick: batches inside its timer, no lock between them, and `sent 0` is the gates

`scripts/credit-ask-tick.sh` (`credit-ask-tick.timer`, :20 and :50) reads the family's arming row and walks one segment
of the need-ask list in batches: each one a read-only `--check-recipients` pass, then an apply of exactly that check's
`--signed-accepted` set, then the cursor saved. Doc: `docs/credit-verification/credit-ask-tick.md`.

- **The credit-group run lock is held only inside one apply, never between batches, and never across :00.** The
  outbound tick does not retry its credit applies on that lock, so the run ends `OUTBOUND_MARGIN_S` before the next :00
  and re-reads the outbound tick's lock before every check and apply.
- **Every apply is read back with the outbound tick's checks** (health, refusal spike, fraud, zero-read, sample)
  before another batch starts; a STOP writes `/etc/hydra/credit-ask-tick.disabled`, and a missing reader refuses the run.
- **A killed run resumes; it never re-sends.** The cursor moves only after a batch is done, and the ledger's claim before
  each post (`verify_ledger.claim` / `blocked_ids`) is what keeps a resumed batch from posting twice. Do not add a
  second idempotency record in the tick: the ledger is the one.

- **A preflight refusal rate is a per-candidate gate population, never evidence of a broken dependency, and it must
  be measured before anyone calls it broken.** `distributor_preflight_not_ok` labels one user's own gate answer and
  the line now carries that answer. Where the measurement lives, with its dates and sources:
  `docs/credit-verification/credit-ask-tick.md` §"`distributor_preflight_not_ok` is a label, not a dependency".
- **A sender whose run outlives its timer starves the family.** The hand-installed tick (3600 s timeout, 30-minute
  timer, no cursor) held the credit-group run lock without a gap, and the outbound tick dropped every credit family
  behind its first apply. A new scheduled sender keeps its hard stop inside its period and yields to the outbound
  tick's lock; `scripts/tests/credit-ask-tick.bats` holds this one to both.
- **A deploy starts the timer again**: the stop that lasts is `/etc/hydra/credit-ask-tick.disabled`.

## The proof refusal: told only where the body is true, and never without a clean read-back

`proof-refusal` (captain 2026-11-15) tells a person why the document they sent did not verify a credit and what
would. Doc: `docs/credit-verification/verify-request-notes.md` §"The proof refusal"; measured audience:
`data/proof-refusal-send-r1/report.md`.

- **A rejected row is listed only where an approved body names the need the READER recorded**
  (`proof_review_decisions.ask_need`; `credit_review/proof_refusal.py` `PAIRS`). Mapping a reason to a need by
  table would have told 422 people a split sheet changes a result the reader said a dashboard screenshot with a
  code changes; those rows are `proof-need-ask`'s. Of 6,659 rejected rows on 2026-11-15, 630 (81 people) were listed and
  40 people could be sent a note on a first run. Never report rejected rows as people this note reaches.
- **`{evidence}` is `proof_reviewer.ASK_LINES` by need code**, pinned to the gate's words by
  `scripts/tests/test_proof_refusal.py`. A reason and need with no approved body refuses the whole note in the
  gate; it never drops a track or borrows another track's reason.
- **The list is not the decision.** The reviewer runs beside the tick, so `proof_refusal.moved` re-reads the
  review row and the newest unreverted decision for the page, and on an apply again per person immediately
  before that person's gate call; a row that moved is not sent under the old reason, since one message per
  request would keep the right one from ever going.
- **One sentence set per track, the closing once, no greeting and no sign-off.** Do not add a line: the reviewer
  approves the note as the rubric's class 2 template and refuses anything beside it.
- **The tick runs `proof_refusal.py readback` before every run** (sent = claimed, 0 hard bounces, 0 spam
  complaints over every note the campaign sent). A stop or an unmeasured read sends none that tick and pages once
  per finding. 100 per tick across paid and free (`PR_CAP`), 395 a day (policy), paid first.

## The notify tick tells every affirmed user and carries the others

`scripts/credit-notify-tick.py` (node-8 `credit-notify-tick.timer`; in git since 2026-11-14, before that a
hand-written host file) walks the untold precedent approvals in chunks; the loop and every stop are
`scripts/credit_review/notify_chunks.py`.

- **No affirmation count abandons a chunk.** The old `aff < 10` skip dropped the affirmed users with the rest. A
  short chunk is told by signing a dry run of exactly its affirmed users, which is `decision_told.signed_subjects`'
  own rule; never change `MIN_SIGNED_DRY` to get a send through or to quiet a log.
- **Everyone not sent is carried into the next chunk with a reason**, except a chunk whose dry run itself did not
  run (`dry_failed`): nothing was learned about those users, so they wait for the next tick instead of making the
  next chunk unreadable too. A stop is per user, per chunk (`dry_failed`) or the run (`kill_file`, `day_cap`, the
  ladder), and `notify-tick/last-run.json` accounts for every untold user.
  `/etc/hydra/credit-notify-tick.disabled` stops this tick alone; `credit-decision-told.disabled` stops the sender.
- **Who was sent is read from the ledger, not the apply's stdout.** `decision_told.py` carries node-8's hand
  patches and the git-wins marker since 2026-11-14, so a deploy writes the repo copy over the host's.
- **Only a `sent` row closes a group; an attempt holds the slot** (captain 2026-11-14). `decision_told.plan()`
  holds `already_told` on a `sent` row for the (user, group) and `slot_wait` for 7 days after the user's latest
  live attempt, confirmed or not. A user with no `sent` row is still not thereby untold: an attempt whose answer
  was lost (timeout, unparseable answer) can carry core's `metadata.decisionNotice.noticeSentAt`, which `plan()`
  drops per request. The tick lists nobody who has a live row (`notify_tick.already_told`), so an unconfirmed
  attempt is made again only from an explicit list: leave out a user core answered `no_channel`, and a notice
  the mail gateway refused with 413 until its limit moves. Measured: `data/precedent-untold-tell-r1/report.md`.
- **The read-back run id comes from the ledger, never from the environment.** `notify_chunks.ladder_state` names a
  prior confirmed send only when the ledger holds MORE apply attempts than `FIRST_LIVE_LIMIT` — a caller cannot
  reach the ladder's second live write without one, so that count is durable proof an operator climbed the rung.
  Below it the tick certifies no read back of its own: the ladder admits exactly one live write (on a ledger with no
  attempt yet, that one user is told), then the run exits 1 with a status line naming the stop, how many untold
  users it blocked and the run to read back. That run id is read from the ledger AFTER the run, so a
  first-ever live run names the run its own apply just wrote, and a ledger that cannot be read back after the run
  writes `notify-tick: run not measured (...)` rather than a stale or `unknown` id. A read-back stop is never
  rendered as "sent 0 this run".
- **A run that cannot be measured says so before it propagates**: any unexpected exception writes
  `notify-tick: run not measured (<type>)`, so the sentinel never reads the previous run's numbers as current.
- **A chunk whose sender call fails outright is a run-level failure, never a quiet zero.** The per-user reasons
  (`dry_failed`, `apply_failed`) stay, and the next chunk is still asked, but `sender_failures` in
  `last-run.json` and a status line leading with `SENDER FAILED in chunk <n> (<dry|apply> rc <n>)` carry it, and
  the tick exits 1. The kill file's rc is excluded: that is the named stop `kill_file`.
- **The class is read by the host's query copied into a core-backend pod, and a copy that fails stops the run.**
  The pod copy is content-addressed (`/tmp/mklist2-<sha256[:12]>.js`), so a failed `kubectl cp` cannot leave an
  older revision of the predicate to be executed; a failed `get pod` stops it too.

## A precedent approval reaches the ledger by a claim before core and a read of core after

precedent_v1 approves in core from a pod that cannot open node-8's SQLite ledger, so no transaction covers both.
`scripts/credit_review/precedent_ledger.py` (doc `docs/credit-verification/precedent-ledger.md`) is the order instead.

- **`claim` before the core write, `reconcile` after, and only `reconcile` writes an approval.** It reads core
  read-only and closes each claim `landed` (decision row, `approved` outcome, move to APPROVED, one transaction) or
  `not_landed` (closed with what core said, nothing else written). A core read that fails writes nothing (exit 4).
- **A claim is never an early `decisions` row.** That table is append-only and seven readers act on a request's
  newest row there; a claim that did not land would stay as an `approve` over the request's hold.
- **Nothing runs `claim` yet.** node-8 runs `/root/prev2.js`, a file in no repository (tracked copy:
  https://github.com/Muso-AI/hydra/pull/1967), and it prints no plan line. Until it does,
  `precedent-ledger-reconcile.timer` (every 10 min, `--since-hours 6`) records approvals from core's recently
  changed rows. Stop switch: `/etc/hydra/precedent-ledger.disabled`.
- **The row keeps `profile_id` and `user_id` NULL** (`evidence_kind` `precedent`): a profile id puts the request in
  the verify-note audience, a user id counts it against the decider's daily caps. Its times are core's
  `approval.at`, so a backfilled row is in no later hour's `applied_1h`.
- **Core's all-time precedent approvals cannot be read in one statement.** The replica cancels at 60 s both the
  filter on `metadata.approval.via` and a 30-day `updatedAt` window; one batch's rows each hold the whole batch's
  precedent sets. `core_since` walks `updatedAt`, halves a cancelled slice, then lists ids and reads by id.
- **An approval with no run name is still an approval.** 9,465 of core's 10,384 (two UPDATEs of 2026-11-10) have
  no `approval.run`; their rows carry `prev-unnamed-<approval time>` (`run_id_of`). Skipping them closed 919.
- **The one-time gap is `precedent_ledger.py backfill` (a plan), then `--apply`, run by hand on node-8 after a
  deploy.** Until it runs, the ledger holds only the approvals of the timer's 6 h window onward.

## "Never asked" is a join by request id, and it is mostly a reading backlog

Measured 2026-11-15, with the tool that reproduces it: `data/never-asked-canary-r1/report.md`.

- **Count it as pending requests no verify-ledger row names, joined by request id.** `pending - ledger ids` as two
  totals subtracts ledger ids that are no longer pending (17,539 that day) and counts no population: 9,078 by
  subtraction, 26,617 by the join.
- **Requests are not customers, and most are not owed an ask.** Of the 26,617: core asked 7,456 itself, 14,756 sit
  behind a proof entry already on file, 413 have no user. A first contact was owed to 238 customers.
- **`metadata.freshDspCapture` is a receipt, never a live state**: approved requests carry the same `partial` /
  `enqueued` values. In flight is an open `dsp_captures` row (`closed = 0`) in `dsp-verify.sqlite`.
- **A refusal rate read from ledger rows alone reads 0.** No `uvn-status` refusal has written a ledger row since
  2026-11-03; they are in the tick's `uvn-status-*-check.json`. Count the check's refusals too.
- `scripts/credit_review/never_asked_digest.py` is an audience and a canary rule (one digest per customer, 500
  measured, continue only under 2%), wired to no sender. A send through it is a decision on copy and campaign,
  not a merge.

## The standing review reads; it never steers

`scripts/standing_review/review.py` (tick `scripts/standing-review-tick.sh`, every 2 h on ak47, the only box that
reaches the reviewer model) samples one plan document plus the commits merged since its cursor and asks a tool-less
reviewer. Operator doc: `docs/standing-review.md`; rubric: `policies/standing-review-rubric.md`.

- **Code decides what pages, not the reviewer's wording.** `judge()` pages only one of six defect classes, marked
  `verified`, with what / blast radius / smallest fix, and every evidence quote found verbatim on a new-side line of the
  sample. Everything else lands in `report.md` with its `why_not`. A clean pass prints nothing.
- **"Could not review" is exit 3, never clean**, and the cursor does not move. An undelivered page stays in the outbox
  and fails the run (exit 2).
- **It has no way to touch a lane**: git is an allowlist of read-only subcommands (`status` is not on it, it rewrites
  the index), every write goes through `Store` under the state directory, and the tick fetches into its own bare
  mirror. Do not add a GitHub client, an inbox write or a status-file write to it; the tests pin their absence.

## Where verifications stand: one read-only page

`scripts/verification-standing.py` prints one screen per request family: open, decided 24h, told 24h,
median and oldest age, last successful send, days to zero, then the credit requests' five tracking
numbers (`OURS`, `sent_this_tick`, `applied_1h`, `decisions_per_intake`, `held_evidence_unbounded`).
`median age` is the median age of an OPEN REQUEST, one sample per request; the per-user figure
(each user's oldest open request) is printed on its own line, labelled.
It reads the queue report's saved snapshot, the verify ledger (`mode=ro`), the sender's tick records
and the outbound policy, and nothing else. The table counts users; a source it cannot read prints
`unmeasured`, never 0; a snapshot older than 2 h is marked `~` on every cell.
`held_evidence_unbounded` is `unmeasured` until a writer records the reason (none does yet).
It is a job, not a command to remember: `verification-standing.timer` saves it to
`/var/lib/hydra/verification-standing/latest.txt` twice an hour, and the unit fails and pages when
a number that has a writer is unmeasured or stale.
`docs/credit-verification/verification-standing.md`.

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
