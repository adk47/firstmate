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

Hydra cuts daily releases off `main` (mirroring openclaw's pattern — no
release branches, no canary; tag is a labeling event, not a gate).

- **Tag format**: `vYYYY.M.D` with no leading zero on month/day
  (e.g., `v2026.5.26`). Multi-cut days append `.N` (`v2026.5.26.1`).
- **How to cut**: `./scripts/release.sh` — opens generated notes in
  `$EDITOR`, then tags, pushes, creates the GH release, and posts a
  Block Kit announcement to #clio_devops via the devops bot.
- **Dry-run**: `DRY_RUN=1 ./scripts/release.sh` previews the notes
  without tagging or publishing.
- **No CHANGELOG.md**: GitHub releases are the changelog. Don't
  introduce a tracked CHANGELOG file.
- **Cron**: `hydra-release.timer` fires Mon..Fri 08:00 Europe/Rome
  on node-8, invoking `scripts/release-cron.sh`. The wrapper operates
  against a **dedicated git checkout at `/var/lib/hydra-release/repo`**
  — NOT `/opt/hydra/`, which is the rsync target and has no `.git`.
  `install-aux-units.sh` initializes the checkout on first deploy
  (clone via `gh repo clone` + local `user.name`/`user.email` for tag
  identity). Each fire: `git fetch && git reset --hard origin/main`
  then `release.sh --no-edit`. Date-gated to first fire on
  2026-05-28T06:00Z; disable with
  `systemctl disable --now hydra-release.timer` if commit-subject
  hygiene goes bad. Inspect upcoming fires with
  `systemctl list-timers hydra-release.timer`.

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
runbook (`scripts/sync-from-server.sh skills --apply` → commit → re-deploy
or `HYDRA_FORCE=1` after verification).

Ack window is 1h by default (`HYDRA_HOTPATCH_ACK_WINDOW`); stale
announcements stop shielding after that. See `scripts/lib/announce-skill-hot-patch.sh`
and `scripts/lib/acknowledge-hot-patch-drift.sh`.

## Codex / OAuth auth is centralized

Codex (`openai/gpt-5.6-sol`/`-luna` via the codex agentRuntime, ChatGPT OAuth)
credentials live in ONE canonical store: the `main` agent at
`/root/.openclaw-main/agents/main/agent/auth-profiles.json`. That file is OUR
source of truth (written by `codex-oauth-refresh.sh`, the sole refresher).
How the RUNTIME consumes it depends on the openclaw version:

- **openclaw >= 2026.7 (current)**: the runtime never reads
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
- **Detect**: `scripts/lib/ensure-codex-auth.sh --check` (exit 1 + names the
  offending stores). **Remediate**: `scripts/lib/ensure-codex-auth.sh`
  (converges every derived store back to canonical). The codex-health
  watchdog independently alerts on `authentication token has been
  invalidated`.
- **Re-auth GOTCHA**: `openclaw models auth login --provider openai-codex`
  with no `--agent` writes to the CONFIGURED-default agent (`clio`), NOT
  `main`. Re-auth MUST land in the canonical `main` store — pass
  `--agent main`. On 7.x, follow ANY re-auth with `codex-auth-sync.sh` (the
  login wrote a store the runtime reads, but canonical + the other derived
  stores must be reconverged). **All THREE accounts** (`aaron@muso.ai`,
  `aarondkaufman@gmail.com`, `aaronkaufman@me.com`) must be logged in — a
  third was linked as of 2026-07-28. Verify with
  `openclaw --profile main models auth list` (expect three `openai:<email>`
  oauth profiles) and `jq -r '.profiles|keys[]'` on canonical
  `auth-profiles.json` (expect the same three under `openai-codex:`).
  Any account missing from EITHER namespace is invisible to that half of the
  system — see the profile-ID namespace rule below.

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
`@openclaw/codex` is pinned to `2026.7.1` (the value + rationale live ONCE in
`scripts/lib/codex-version.sh`). History: 2026-06-16 → 2026-07-14 it was
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

**The token LAPSE is a FOURTH, distinct failure — a consequence of keeping the bundled
`openai` plugin DISABLED.** `authentication token is expired` (`auth error code:
token_expired`, all three guards CLEAN, `refresh_token_reused`/`invalid_api_key` = 0) is a
pure OAuth credential lapse. The `openai` plugin stays disabled (on 6.x to dodge #90925; on
7.x because it loads DESPITE `plugins.allow` and hijacks provider `openai` onto the api-key
route — hence the explicit `plugins.entries.openai={enabled:false}` in both repo configs).
That plugin owns BOTH the refresh-on-use machinery AND the device-code login — so nothing
in-process auto-refreshes codex (it lapses ~every 10 days; upstream openclaw#57399 wontfix)
AND `openclaw models auth login --provider openai-codex --device-code` fails "No provider
plugins found" (there is also NO `openclaw models auth refresh` command).
**Recovery = `scripts/lib/codex-oauth-refresh.sh`** — we do the `grant_type=refresh_token` POST
to `auth.openai.com/oauth/token` ourselves, write the rotated token into canonical, fan the
new access token out via `codex-auth-sync.sh` (7.x), then restart (the gateway only loads the
token at startup). **Prevention = the twice-weekly `codex-token-refresh.timer`** (Sun+Wed
04:00 UTC, refresh + sync + restart) keeps it always fresh — and on 7.x it is also what makes
the single-refresher invariant safe: derived stores carry a sentinel refresh token, so only
this script can ever rotate the chain. `scripts/codex-keepalive.sh` (15m) is the safety-net pager. (`models status --check` always
exits 1 here — it flags the disabled `openai` provider as "missing", NOT a codex signal.) See
RUNBOOK §Troubleshooting → "Codex Token Lapse (`token_expired`)" and `docs/lessons/openclaw-and-codex.md`.

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
~2h. **Recovery needs a browser**: `scripts/lib/codex-reauth.sh` drives the codex CLI's own
`login --device-auth` (the vendored binary under `@openclaw/codex`), merges into canonical,
shreds the scratch credential, syncs and restarts. **`openclaw models auth login --provider
openai-codex --device-code` does NOT work here** — the `openai` plugin owns that flow and is
disabled AND off `plugins.allow`; enabling it transiently reintroduces #90925 while main
self-restarts on memory pressure every ~40-60min. A raw curl to
`auth.openai.com/oauth/device/code` is Cloudflare-blocked (403).

**Codex profile IDs live in THREE namespaces — do not "unify" them.**
(1) canonical `auth-profiles.json` uses **`openai-codex:<email>`** — `codex-auth-sync.sh`
selects on that prefix; (2) the derived runtime store (`auth_profile_store` sqlite) and
(3) `auth.order.openai` in `openclaw-*.json` both use **`openai:<email>`**. openclaw
resolves auth.order ids with an EXACT key lookup (`store.profiles[profileId]`) — only the
provider KEY is normalized, never the id — so an `openai-codex:` entry in auth.order
resolves to NOTHING and the fallback list is silently empty. That is why nothing failed over
on 2026-07-27. Conversely, an `openai:`-keyed profile in *canonical* is invisible to
`codex-auth-sync.sh` (this swallowed a valid recovery credential for 23min the same day).
Verify live ids with `openclaw --profile main models auth list`; the namespace is gated in
CI by `scripts/validate-shared-config.sh`.

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
