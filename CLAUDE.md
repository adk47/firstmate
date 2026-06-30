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

Codex (`openai/gpt-5.5` via the codex agentRuntime, ChatGPT OAuth)
credentials live in ONE canonical store: the `main` agent at
`/root/.openclaw-main/agents/main/agent/auth-profiles.json` (openclaw's
`DEFAULT_AGENT_ID="main"` is the inheritance base). Every OTHER agent's
`auth-profiles.json` + `auth-state.json` is a **symlink** to it — openclaw
resolves the symlink to its target before its atomic rename, so the links
survive token refresh.

- **NEVER copy, seed, or fan-out codex `auth-profiles.json` into per-agent
  stores.** OpenAI codex uses single-use rotating refresh tokens under a
  per-profile lock (upstream #26322); independent per-agent refreshes
  mutually invalidate the token and kill ALL codex agents at once
  (incident 2026-05-29: 6 agents degraded to Sonnet fallback for hours).
- **Detect**: `scripts/lib/ensure-codex-auth.sh --check` (exit 1 + names the
  offending stores). **Remediate**: `scripts/lib/ensure-codex-auth.sh`
  (re-symlinks every agent store back to canonical). The codex-health
  watchdog independently alerts on `authentication token has been
  invalidated`.
- **Re-auth GOTCHA**: `openclaw models auth login --provider openai-codex`
  with no `--agent` writes to the CONFIGURED-default agent (`clio`), NOT
  `main`. Re-auth MUST land in the canonical `main` store — pass
  `--agent main`, or rely on `clio` already being symlinked to canonical
  (the write follows the symlink). Both accounts (`aaron@muso.ai`,
  `aaronkaufman@me.com`) must be logged in.

This generalizes PR #376 (edge/Caroline symlink self-heal + fail-loud
codex-health watchdog) to the whole fleet. Prose alone is not enforcement —
the script and watchdog are. See RUNBOOK §Troubleshooting → "Codex auth
invalidated / silent Sonnet fallback" for the recovery sequence.

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

**The codex PLUGIN is pinned BELOW the runtime — never float it.** `@openclaw/codex`
is pinned to `2026.5.27` (the value + rationale live ONCE in
`scripts/lib/codex-version.sh`), deliberately behind the 2026.6.1 runtime, because
`@openclaw/codex@2026.6.x`'s "OpenAI route unification" (upstream #90925/#90448,
OPEN) routes `openai/gpt-5.5` to the OpenAI **api-key** endpoint instead of the
Codex app-server **OAuth** route. hydra is OAuth-only (placeholder `OPENAI_API_KEY`),
so on 6.x every codex call 401s `invalid_api_key` and the whole fleet drops to
`openrouter/gpt-5.4-mini` (incident 2026-06-19, when a manual `plugins install
@openclaw/codex@2026.6.1 --force` floated codex off the pin — the token was fine;
re-auth did nothing). **NEVER `plugins install`/`update` codex off the pin**; to
move it, bump `codex-version.sh`. **Detect**:
`scripts/lib/ensure-codex-version-pinned.sh --check` (the failing-URL tell:
`api.openai.com/v1/responses` = regressed vs `chatgpt.com/backend-api/codex` =
OAuth-ok). **Remediate/self-heal**: same script no args (re-pins to canonical;
wired into ExecStartPre via `openclaw-pre-start-heal.sh`, so a float self-heals on
restart). The watchdog pages on the `invalid_api_key` signature (main+edge), on the
`authentication token is expired` OAuth-lapse signature, and on version drift.
**Re-verify codex still serves gpt-5.5 on EVERY openclaw bump** — revert to runtime
lockstep only once #90925 ships fixed. See RUNBOOK §Troubleshooting → "Codex Plugin
Floated Off Pin".

**The token LAPSE is a FOURTH, distinct failure — and its root cause is our own #90925
mitigation.** `authentication token is expired` (`auth error code: token_expired`, on the
`chatgpt.com/backend-api/codex` route, all three guards CLEAN, `refresh_token_reused`
/`invalid_api_key` = 0) is a pure OAuth credential lapse. We keep the bundled `openai` plugin
DISABLED to dodge #90925, but that plugin owns BOTH the refresh-on-use machinery AND the
device-code login — so nothing auto-refreshes codex (it lapses ~every 10 days; upstream
openclaw#57399 wontfix) AND `openclaw models auth login --provider openai-codex --device-code`
fails "No provider plugins found" (there is also NO `openclaw models auth refresh` command).
**Recovery = `scripts/lib/codex-oauth-refresh.sh`** — we do the `grant_type=refresh_token` POST
to `auth.openai.com/oauth/token` ourselves and write the rotated token into canonical, then
restart (the gateway only loads the token at startup). **Prevention = the twice-weekly
`codex-token-refresh.timer`** (Sun+Wed 04:00 UTC, refresh + restart) keeps it always fresh;
`scripts/codex-keepalive.sh` (15m) is the safety-net pager. (`models status --check` always
exits 1 here — it flags the disabled `openai` provider as "missing", NOT a codex signal.) See
[[reference_codex_token_expired_third_signature]].

**Deferred-upgrade tripwire (decided 2026-06-29).** We deliberately HOLD openclaw at
2026.6.1 + codex 2026.5.27 rather than jumping to latest stable (2026.6.10), because the two
things that would let us "drop the hacks and go lockstep" are BOTH still OPEN: #90925 (codex
OAuth-route regression — can't un-pin codex) AND #90575 (no native cross-process
shared-credential store — the 6.5 auth→SQLite migration kills the symlink fabric with nothing
to replace it). Revisit the 6.10 jump only when BOTH close. The 6.5 auth→SQLite migration is
ALSO one-way (cold SQLite state-archive required for rollback, not the JSON).

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
`muso-read`, `muso-deep-research`, …) is **absent from agents' invokable catalog**, even
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
   `cron-jobs.json` (sessionTarget=main)
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
