# OpenClaw platform and Codex / OAuth runtime lessons

Hard-won operational lessons about the OpenClaw gateway (config, state paths,
skills, cron, plugins, MCP, audit, Slack) and the Codex / ChatGPT-OAuth agent
runtime. These are durable mechanisms first; specific versions and model ids
(openclaw 2026.5.x / 2026.6.1, `openai/gpt-5.5`, etc.) appear only as dated
examples and may have moved on. Verify against the live gateway before acting on
any single claim. Live hydra paths (`/root/.openclaw-<profile>/`,
`/etc/openclaw/*.env`) are stable enough to cite directly.

---

## OpenClaw gateway, config, skills, cron, plugins, MCP

### Config and state paths

**Profile state dirs are hyphenated, not nested.** `--profile <name>` puts state
at `/root/.openclaw-<name>/` (e.g. `-main`, `-edge`, `-dev`), NOT
`/root/.openclaw/<name>/`. The legacy `/root/.openclaw/` is still dual-written by
deploy but is not read by any profiled gateway. Hot-patches and inspections that
target the legacy path silently hit the wrong (stale) file. `systemctl show -p
Environment openclaw-gateway-main` shows the real config dir.

**Pin `OPENCLAW_STATE_DIR` per-profile or the daemon injects a stale skill
catalog fleet-wide.** The long-running daemon resolves the managed-skills tier
(plus OAuth dir and codex refresh-lock) via a profile-BLIND resolver that ignores
the runtime `--profile`; with `OPENCLAW_STATE_DIR` unset it falls back to the
frozen legacy `/root/.openclaw/skills` catalog and every agent loses skills added
since that snapshot. The CLI (`openclaw --profile main skills list`) gets
`--profile` and looks fine, so it is NOT a valid check; verify a fresh agent
session's injected catalog or `/proc/<pid>/environ`. Fix: pin in the per-profile
systemd env file (`/etc/openclaw/main.env` -> `OPENCLAW_STATE_DIR=/root/.openclaw-main`),
NEVER in `shared.env` (both gateways load it -> one state dir for both). Do NOT
`rm /root/.openclaw` (a missing dir falls to an empty one = total skill loss);
pin, don't delete.

**Source live env from the active unit's files, not the legacy drop-in.** For
ssh-testing with `MUSO_API_URL`, Intercom/ClickUp tokens, etc., `set -a; . /etc/openclaw/shared.env; . /etc/openclaw/main.env; set +a`. Confirm via `systemctl
cat openclaw-gateway-main.service` `EnvironmentFile=` directives - do NOT grep the
filesystem and grab the first match (that often finds the legacy-disabled
`openclaw-gateway.service.d.legacy-disabled-*/env.conf`, a plaintext secret dump
slated for deletion).

**Watch for the legacy zombie gateway.** A pre-multi-profile
`openclaw-gateway.service` (no `-main` suffix) can be `disabled` but still
`active` (systemd doesn't stop a running disabled unit). It binds port 18789 and
openclaw's service-mode pid-clearing makes it SIGTERM the real
`openclaw-gateway-main` on every start -> 20-30s crash loop. Detect:
`systemctl list-units 'openclaw-gateway*' --all`; only `-main`/`-edge` should be
active. Symptom: `cron status --json .storePath` returns the legacy
`/root/.openclaw/cron/jobs.json`.

**No custom keys in `openclaw.json`.** The root Zod schema rejects unknown keys
(`_comment` fails validation and the gateway won't start). Comment in deploy
scripts or separate docs instead.

**Prefer `openclaw config set` for live edits (audit-clean).** It's openclaw's own
config-io writer, so it logs to `config-audit.jsonl` and the OOB-write audit
watcher does NOT fire (no `announce-legit-write.sh` needed) - the key difference
from a hand jq + atomic-rename write. Use `--strict-json` for array/object values,
`--dry-run` to validate. Config is snapshot at gateway start, so the change is NOT
live until a restart. The live `/root/.openclaw-<profile>/openclaw.json` is NOT
byte-identical to the repo `openclaw-<profile>.json` (deploy transforms it), so
hot-patch the specific path in place; never scp the repo file over live config.

**Secret-file perms are fail-closed.** A whole-fleet outage where
`ensure-codex-auth.sh --check` and the refresh-lock check are both CLEAN, yet no
agent responds and both gateways are systemd-`failed`, is usually a too-open
secret file. openclaw refuses to start if a `secrets.providers.*.path` file is
world/group-readable (`permissions are too open ... required secrets are
unavailable`). Fix: `chmod 600 /opt/hydra/secrets/*.json` then `reset-failed` +
restart both gateways. A live config reload (triggered by any deploy that changes
`openclaw.json`) re-validates the secret provider, so a latent 644 can stay hidden
until the next reload.

**Never `openclaw doctor --fix` on a system-systemd-managed gateway.** It creates a
competing user-level unit (`~/.config/systemd/user/openclaw-gateway-<profile>.service`)
that fights the system unit (immediate SIGTERM after start), and it applies ALL
schema migrations in one shot. If you must run it, do so with a backup +
post-validation and then remove any user unit it created.

### Skills loading

**Managed-skills tier resolves under the config dir.** Tier-4 "managed" skills
load from `<CONFIG_DIR>/skills/<skill>/SKILL.md`, where `CONFIG_DIR` =
`OPENCLAW_STATE_DIR` else `dirname(OPENCLAW_CONFIG_PATH)` else `$HOME/.openclaw`.
For a profiled gateway that's `/root/.openclaw-<profile>/skills/`. Each profile
needs its OWN populated managed dir. `/root/.openclaw/skills/` (no suffix) is the
CLI-without-profile dir, not what gateways read; `skills/skills/` (double-nested)
is vestigial and read by nothing.

**Workspace skill discovery is one level deep.** The resolver does a single
non-recursive scan of `workspaceDir/skills/*/SKILL.md`, skipping only
dot-prefixed dirs and `node_modules` (NOT underscore-prefixed). So
`skills/_archive/<retired>/SKILL.md` at depth 2 never loads - but a `SKILL.md`
dropped DIRECTLY in `skills/_archive/` WOULD load. For safe archiving use a
dot-prefixed `.archive/` or keep archives outside `skills/`.

**Pin the absolute skill dir in workspace-native skills.** A cron-invoked skill
under `workspaces/<agent>/skills/` (not the managed tier) can false-fail when the
model improvises the `cd` target and picks the managed-skills convention
`$HOME/.openclaw/skills/<name>` (which doesn't exist for it). That single early
`cd ... || exit 1` error trips the run-outcome classifier and the delivery is
suppressed even though the agent recovers. Fix: pin the absolute workspace path as
the first line. Do NOT use the `${OPENCLAW_STATE_DIR:-$HOME/.openclaw}/skills/`
idiom for a workspace-native skill - it resolves to the managed tier (filled only
from `skills-all/`), so it's empty there.

### Cron

**Two payload shapes, strictly enforced by the CLI.** "Run a task" = `--session
isolated` (default) + `--message` + `--announce --channel slack --to <target>`;
`--at "+0s"` makes a one-shot (defaults `deleteAfterRun:true`). `--session main`
is different: it REQUIRES `--system-event` and REFUSES `--message`/`--announce`/`--no-deliver`.
`--to "user:U..."` for DMs, `"channel:C..."` for channels. `openclaw cron add` is
the fire-and-forget primitive (CLI reaches the gateway tokenless as root, so CI
runners can dispatch the same way); `openclaw agent` is synchronous and blocks.

**Isolated cron RETAINS `exec` on modern builds.** The older "#65981: isolated
cron loses tools -> use `sessionTarget: main`" warning is stale for >=2026.5.27
(verified: all prod crons are `isolated`+`agentTurn`, exec-driven jobs have
hundreds of runs). Verify before reaching for the main-session workaround, which
the CLI now makes awkward. (Browser still needs the full top-level `browser`
block regardless.)

**A run is `error` if its last error payload has no deliverable reply after it.**
A non-zero `exec` exit IS an error payload (`gh pr checks` on a not-green PR, a
gate wrapper that declines), so wrap intentional-nonzero commands with `|| true`
/ `|| echo`. A successful `echo`/exec does NOT rescue the outcome - the
classifier needs a delivered REPLY payload (text/media), not a tool result.
`--delete-after-run` deletes only on `outcome=ok`, so failed one-shots linger;
sweep them. Firing evidence for isolated turns is NOT in journald - read
`/root/.openclaw-<profile>/cron/runs/<jobId>.jsonl` (one line per run with
status/delivered/model/durationMs).

**`payload.model` is validated against `agents.defaults.models`; AGENT models are
not.** A model absent from the allowlist makes the SCHEDULED run reject at
preflight (`status:error`, `model:null`, agent never runs); already-loaded jobs
are grandfathered until next touched, so failures look intermittent. Right fix =
ADD the model to `agents.defaults.models` (keeps crons on cheap codex, matches the
CI gate); wrong fix = flip crons to `openrouter/...` (costs money and fails
`validate-config-matrix.sh`). The asymmetry: a fleet agent's `model.primary`/`fallbacks`
in `agents.list[]` are NOT allowlist-gated by any CI check (add anyway for runtime
correctness). `cron add` cannot set `payload.fallbacks` (no flag); add by hand and
let deploy reconcile by id. Silent cron failures had no alerting until a watchdog
was added (`cron-health-watchdog.sh`).

**Silent-on-empty crons must emit `NO_REPLY` verbatim.** openclaw's `silentToken`
defaults to `NO_REPLY` with no per-cron override wired; a cron emitting any other
token (e.g. `NO_MEETING`) posts it to Slack every run.

### Memory and bootstrap

**Over-cap bootstrap files are MIDDLE-dropped, not tail-dropped.** `bootstrapMaxChars`
(hydra 40000, upstream default lower) is a per-file cap on each workspace file
(SOUL.md, MEMORY.md, ...). An over-cap file keeps head ~75% + tail ~25% and
deletes the MIDDLE, so load-bearing rules in the middle silently vanish - placing
rules at top OR bottom both survive, and the only real fix is keeping the file
under cap (the on-disk file is untouched; only the injected copy trims). Tell:
journald `workspace bootstrap file SOUL.md is N chars (limit M); truncating in
injected context`. Count chars with `wc -m` to match openclaw. Corollary:
`reference/*.md` is NOT auto-indexed; make it `memory_search`-able via
`memorySearch.extraPaths` (indexes without bootstrapping). `memory/**` is
auto-indexed and must NOT be listed there.

**`memory_search`'s default min-score floor drops valid natural-language
queries.** A real customer question can score ~0.33 against the exact answer chunk
and return "No matches" while a 2-word keyword query passes at ~0.57. For
MANDATORY pre-retrieval RAG (inject-then-generate) use `minScore: 0` (or ~0.05) +
`maxResults: 5` and let the model judge relevance; a floor reintroduces "retrieved
nothing -> answered ungrounded." Post-deploy RAG validators must also pass
`--min-score 0` or they false-fail on a healthy index.

**Version bumps PAUSE every vector memory index.** On gateway boot openclaw
validates index identity and PAUSES (does not auto-rebuild) any index whose stored
metadata predates a format change, silently breaking RAG fleet-wide until a forced
reindex. Symptom: `index metadata is missing. Vector memory search is paused`.
Fix: `openclaw --profile <p> memory index --force --agent <id>` (needs the gateway
running). Enumerate agents via `/root/.openclaw-<profile>/memory/*.sqlite`. A
`--force` pass can lose the race with a busy gateway on a small index and re-pause,
so verify (re-probe for "paused") and retry once.

**Dreaming is gateway-global, not per-agent scopable.** `dreaming.enabled` lives at
`plugins.entries.memory-core.config.dreaming` with no agent/scope field; the engine
fans out over every agent in `agents.list`. Storage is per-agent
(`/root/.openclaw-<profile>/memory/<agentId>.sqlite`) but that does not gate the
consolidation pass. The only clean isolation is a dedicated profile-gateway. For a
per-agent self-improvement loop, write the agent's own `MEMORY.md` directly (there
is no agent-facing memory WRITE tool; `memorySearch` is read-only).

### Tool policy and hooks

**Per-agent tool restriction = `agents.list[].tools.deny`.** There is no
`allowedTools` key. `deny` wins over profile/provider rules (the reliable lockout);
per-agent `tools.allow` is ADDITIVE (only GLOBAL `tools.allow` is an absolute
replace), so to remove a globally-granted tool from one agent use `tools.deny`,
not an allowlist. `policies/tool-deny-lists.yaml` is DECLARATIVE-ONLY (consumed by
UI/deploy/CI ratchet), NOT translated into the runtime config.

**`tools.deny` does not block `exec curl` against `/tools/invoke`.** A YOLO-mode
agent can bypass per-agent deny via shell + the gateway bearer token. The layer for
that is gateway-level (`gateway.tools.deny`), or enforce at the shell boundary.

**`before_tool_call` is not a security gate for `exec` in YOLO mode.** It fires on
only a handful of exec calls per session (mostly early `export`s) and silently
no-ops for the rest; web_fetch/browser hooks were never seen firing. Enforce
policy at the shell boundary (a bash wrapper that sees 100% of traffic and reads
the agent's own authoritative session log), not the plugin boundary. Reliable
hooks: `inbound_claim`, `before_tool_call` on `web_search`, `session_start/end`,
`tool_result_persist` (observe/redact only). Register with `api.on<K>(name,
handler, {priority})`, not `api.registerHook`.

### Plugins and packaging

**`plugins install` refuses to overwrite; version-pin upgrades need `--force
--pin`.** Any deploy step that pins a plugin to an exact version no-ops on a fresh
install but FATALs on the first real upgrade (`plugin already exists ... rerun with
--force`). `--force` overwrites in place; `--pin` records the exact resolved
version so a stray `plugins update --all` can't float it. Install only writes
disk - a gateway restart loads the new plugin. Every runtime bump must re-pin all
runtime-coupled `@openclaw/*` harness/channel plugins in lockstep (an externalized
plugin left behind can reject the new provider and silently degrade agents to
fallback).

**Packaging contract: ship compiled `dist/index.js`.** Installed plugins must ship
`dist/index.js` (`build: tsc` in package.json; `openclaw.extensions` points at
`./dist/index.js`). Channel plugins need full `ChannelMeta` (id, label,
selectionLabel, docsPath, blurb). Slack is externalized to `@openclaw/slack`
(install per-profile or every Slack channel stays offline). Deploy and CI both use
`pnpm install --frozen-lockfile` against the committed lockfile, so regenerate
plugin `pnpm-lock.yaml` against the new SDK in the SAME PR as any `OPENCLAW_VERSION`
bump, or CI-green stops implying deploy-installs-cleanly.

**Channel-plugin SDK gotchas.** Provide `isConfigured` (else `configured:false`,
accounts never start) and override `isEnabled` (Zod defaults don't apply at gateway
level, so `account.enabled` is `undefined`). Use `defineChannelPluginEntry` from
`openclaw/plugin-sdk/core`. The gateway passes `undefined` cfg to lifecycle
callbacks (capture `api.config` in `registerFull`). Replies go through `deliver()`,
not `sendText`. Plugin directory basename = extension id. Install per-profile,
files `chown root:root` (openclaw blocks non-root ownership), `rm -rf` the old dir
before reinstall, and declare openclaw as a `peerDependency`.

**Repair a present-but-unloaded plugin with `enable`, not `install`.** When the
extension dir exists but its `plugins.entries.<id>` keys are missing, `plugins
install` REFUSES (`plugin already exists`); `plugins enable <id>` repairs the
config and loads on next start (it skips `plugins.installs` metadata, needed only
for `plugins update` tracking).

**`plugin disable` does not validate channel dependencies -> crash loop.**
Disabling a channel-bearing plugin renames its dir but leaves the `channels.<name>`
entry; the next start hard-fails config validation, and with systemd
`Restart=always` the gateway crash-loops (the plugin/allow warnings are non-fatal;
only the channel reference is fatal). Remove the `channels.<name>` block first and
restart once to confirm a clean validate before walking away.

### MCP

**Remote MCP must use `transport: "streamable-http"`, never `npx mcp-remote`.**
`mcp-remote` children inherit the gateway's process group and accumulate on
re-register; reaping them by pgid kills the gateway itself (caused a real outage).
Canonical shape: `{"transport":"streamable-http","url":"...","headers":{...}}` (or
`"sse"`). A config lint rejects the `command: npx|npm` + `mcp-remote` shape. If a
provider only authenticates via mcp-remote's interactive OAuth, the lint still
rejects it deliberately; hold the integration until they offer static-token
streamable-HTTP. Register live with `openclaw --profile main mcp set "<Name>"
'{...}'`; repo `openclaw-*.json` keeps `.mcp.servers` empty so tokens stay off git.

**MCP tool ids are `<safeServerName>__<toolName>` (double underscore).** Server and
tool names are sanitized (`[^A-Za-z0-9_-]` -> `-`, prefix `mcp-` if not starting
with a letter) and truncated (server 30, tool 64 chars), case preserved. `tools.deny`
is literal Set-membership with NO glob expansion, so list each full tool id; a
truncated/sanitized name can differ from what you expect. A second server colliding
on the safe-name gets a `-2` suffix, silently breaking existing deny entries. Grep
the gateway log for `[bundle-mcp] server key "<raw>" registered as "<safeName>"`.

**`mcp set`/`mcp unset` refuse configs containing a legacy `plugins.installs`
key** even though the runtime tolerates it (`Unrecognized key: "installs"`). On an
unmigrated config, hot-patch via jq + `announce-legit-write.sh` + atomic rename
instead. `openclaw doctor --fix` would migrate it but applies all migrations at
once (needs controlled run + backup).

### Audit and legit-write

**Atomic-rename writers to `openclaw.json` MUST call `announce-legit-write.sh`
first.** Any code path that renames into `/root/.openclaw-{main,edge,dev}/openclaw.json`
must call it immediately before the rename with `ANNOUNCE_SHA` set to the sha256 of
the bytes, or the OOB-write audit watcher Slack-alerts in #clio_devops. The audit
window is 120s and matches on path AND sha256 (a stale entry can't suppress a
different write). `openclaw config set` does NOT need this (it's audit-logged).

**`config-audit.jsonl` only logs writes through openclaw's own config-io.** Manual
`vim`/`jq | mv`/`sed -i`/dashboard edits leave NO audit entry (mtime advances,
nothing records who). So when `openclaw.json` shows an unexpected diff, the ABSENCE
of a recent audit entry is itself diagnostic (the change came from outside
openclaw). Cross-reference `find -newer`, journald, bash history.

**Most "Out-of-band write detected" alerts are benign and you-triggered.** They
fire when someone runs an `openclaw` CLI command or hand-edits live config; routine
deploys are silent (they announce). A later suppression branch silences openclaw's
own gracefully-accepted self-persists, but a REJECTED write (the crash-loop class)
and a plain external hand-edit still alert. Do not remove the watcher - it's the
safety net for schema-invalid writes that crash-loop the gateway.

### Slack and pairing

**`pairing approve` on an empty `commands.ownerAllowFrom` is an owner grant.** If
`commands.ownerAllowFrom` is empty, approving the first Slack sender auto-fills it
with that sender, making them sole command owner (privileged-command rights, not
just chat). Check `jq .commands.ownerAllowFrom` BEFORE approving.

**Per-agent Slack allowlists are mtime+size-cached (no restart needed).** Files
live at `/root/.openclaw-<profile>/credentials/slack-<agent>-allowFrom.json`
(`{"version":1,"allowFrom":["U...",...]}`). A direct edit that changes mtime or
size self-invalidates the read cache, honored on the next inbound message. There is
NO approve-by-user-id CLI (only `pairing approve <code>` from a user's DM). IDs ->
names is a blind spot (no Slack app has `users:read`; `channels resolve` returns
`resolved:false`), so get the mapping from a human. `credentials/` is not covered
by `announce-legit-write.sh`.

**Slack visual feedback needs two keys together.** Lifecycle emojis require BOTH
`messages.statusReactions.enabled:true` AND `messages.groupChat.visibleReplies:"automatic"`
(without the second, group/channel chats resolve to message-tool-only -> ack
reaction disabled -> silent emojis). Native streaming requires a thread-reply
target; `replyToMode` is strictly `off|first|all|batched` (no `"thread"` value),
and `"all"` already threads every top-level channel message. `botUserId` is
auto-resolved at boot via `auth.test()` with no Slack config override; if it fails
(`botUserId=""`) every `@Bot` mention silently fails the include-check (clean
restart to recover).

### Misc runtime mechanics

**`/hooks/agent`: `channel` is the channel TYPE, not the id.** The native webhook
(`POST /hooks/agent`, port 18789, enabled per-profile via `.hooks`) spawns an
isolated agent turn. `channel` is `last|slack|intercom`; the actual Slack channel
id goes in `to`. The hooks token MUST be distinct from `gateway.auth.token`.
Webhook input is wrapped in untrusted-content blocks. Known gap: `deliver:"slack"`
auto-delivery doesn't propagate `to` to the message tool's target, so have the
agent address the reply itself.

**Inbound vision is `image/*` only; PDFs are a separate path.** A PDF in the
inbound media is silently dropped from vision - rasterize pages to PNG and forward
those as `image/*` (host `pdftoppm`). PDF TEXT comes from the bundled
`document-extract` plugin (disabled by default; limits ~5MB / 4 pages / 60k chars /
200 min text). The media-path allowlist is enforced; the safe default is
`<stateDir>/media`. Vision per-image cap ~10MB.

**The browser tool needs an explicit full config block.** It is not default-on
despite the manifest's `enabledByDefault`; the top-level `browser.{enabled,
executablePath, headless, noSandbox, remoteCdpTimeoutMs, remoteCdpHandshakeTimeoutMs}`
must all be present (root+systemd needs `noSandbox`, no X server needs `headless`,
autodetect misses the playwright chrome path, 5s CDP timeouts are too short for
cold start). `browser.*` changes require a full restart, not a reload.

**`session.maintenance` is native; default is `warn` (does nothing).** Set
`mode:"enforce"` with `pruneAfter`/`maxEntries` to actually bound the session
store. Note `pruneStaleEntries` has no special-case for `:main`/`:cron:*` keys, and
`sessions.json` inlines large per-entry snapshots - capacity-plan accordingly.

**`sessions_send` (underscore) is the real inter-agent tool.** It dominates live
transcripts and the installed runtime with zero "tool not found" errors; a
dot-namespaced `sessions.send` also exists but is the minority. Do NOT "fix" souls
that call `sessions_send` to the dot form - that regresses correct calls. Audit
claims about runtime tool names must be checked against the live runtime.

**The heartbeat poll uses the agent's PRIMARY model, default-on, every ~30 min.**
An always-on agent pinned to an expensive primary drains it 24/7 regardless of
human activity. To make it cheaper, flip `model.primary` (the heartbeat follows
it); a `heartbeat.model` override is ignored at runtime. Audit per-source model
spend via `agents/<id>/*.trajectory.jsonl` (interactive) and
`cron/runs/<jobId>.jsonl` (per-run summaries).

**Lobster (the workflow engine) is not bundled; invoke deterministically via
`/tools/invoke`.** Install `@openclaw/lobster` per-profile (announce + restart),
enable with `tools.alsoAllow:["lobster"]` (covers both agent use and the HTTP
endpoint). Run via `POST /tools/invoke` (Bearer = `gateway.auth.token`,
loopback-only; the HTTP path applies an extra deny list of `exec`/`sessions_send`/etc
but NOT `lobster`). The single `pipeline` arg is overloaded: inline DSL
(pipe-separated) vs a `.lobster` file path (YAML) - inline YAML fails silently.
Until a native `kind: lobster` cron payload lands, the systemd-timer ->
`/tools/invoke` pattern is the deterministic trigger.

---

## Codex / OAuth runtime

The FOUR canonical Codex failure modes are documented as the source of truth
elsewhere in this repo and are NOT repeated here: see the "Codex / OAuth auth is
centralized" section of the top-level `CLAUDE.md`, and the matching entries under
Troubleshooting in `docs/runbooks/RUNBOOK.md` ("Codex Auth Invalidated / Silent
Sonnet Fallback" = auth fan-out, "Codex Token Lapse (`token_expired`)" = OAuth
credential lapse, "Codex Refresh-Token Race (`refresh_token_reused`)" =
cross-process refresh collision, "Codex Plugin Floated Off Pin / api-key-route
401 (#90925)" = plugin version drift). Everything below is the ADDITIONAL Codex
mechanics those two files don't cover.

### Harness and runtime basics

**Codex is an agent runtime/harness selected by the model prefix, not a
provider.** Config-only, no sidecar: provider block `models.providers.openai: {}`
(bare unless going through Azure), agent model ref `openai/gpt-5.5` (the `openai/*`
prefix triggers the bundled `codex` harness), `auth.order.openai:
["openai-codex:<email>"]` (OAuth subscription; falls through to `openai:*` API
key), and `plugins.entries.codex: {enabled:true}` (bundled, must be enabled).
`openrouter/...` fallbacks remain valid alongside it - cross-provider fallback
chains work fleet-wide. Swapping an OpenRouter OpenAI agent to a flat-fee Codex
subscription is a config edit + an OAuth bootstrap on the live node + egress for
`chatgpt.com:443` / `api.openai.com:443`.

**Session compaction has its own model path that bypasses the codex OAuth runtime — so
`invalid_api_key` 401s with the pin CLEAN are compaction, not a #90925 float.** A
non-manual (`cli_budget`) compaction logs `[agent/embedded] skipping codex app-server
compaction for non-manual trigger` and resolves a *separate* embedded summarizer target
(`resolveEmbeddedCompactionTarget`) that routes `openai/gpt-5.5` through the raw
`[openai-transport] api=openai-responses` (api-key) path — hitting hydra's placeholder
`OPENAI_API_KEY` → 401 → fallback to `openrouter/openai/gpt-5.4-mini` **for that one
compaction**, while normal agent turns keep serving on OAuth. This is a STRUCTURAL path
present even at the pinned codex `2026.5.27`, distinct from #90925 (which mis-routes
*every* turn only when floated to 6.x). Distinguish the two by the pin
(`ensure-codex-version-pinned.sh --check`): drifted = real float (whole fleet on mini);
clean = compaction-only (fleet healthy). Both the watchdog float alert and the
admin/Stripe write-health gate (`codex_health_gate`) pin-gate the api-key signal so a
compaction loop no longer false-pages or false-blocks writes
(`codex_apikey_route_verdict` / `codex_pin_check_exit` in `scripts/lib/codex-health.sh`;
root-caused 2026-07-06). Do NOT "fix" it with `agents.defaults.compaction.model` —
openclaw docs say don't set it on Codex-backed agents (it emits an "override ignored"
warning), and the fallback already lands on the exact model you'd pick.

### Auth: one canonical store, shared by symlink (never fan out)

**Share ONE Codex credential across all agents; never give an agent its own copy.** The
credential lives in ONE canonical store, the `main` agent's `auth-profiles.json` at
`/root/.openclaw-<profile>/agents/main/agent/auth-profiles.json` (`main` is the hardcoded
`DEFAULT_AGENT_ID` and the inheritance base, NOT the configured-default agent like `clio`).
openclaw natively supports read-through inheritance (a non-`main` agent with no local store
reads main's via `mergeAuthProfileStores(main, agentStore)`), but current hydra doctrine does
NOT rely on that alone: `scripts/lib/ensure-codex-auth.sh` symlinks every non-canonical agent's
`auth-profiles.json` + `auth-state.json` to the canonical files fleet-wide (main AND edge), so
all agents read and write the same bytes and a refresh by any agent advances the one shared
single-use token in place. Its `--check` guard treats any non-canonical store that is a regular
file carrying an `openai-codex:*` profile as a fan-out violation. (A separate workspace like
`.openclaw-edge` has its own `main` and cannot inherit across workspaces, so edge in particular
MUST be symlinked.)

**NEVER fan out per-agent Codex auth copies.** Copying the OAuth profile (which
carries a single-use rotating refresh token under a per-profile lock) into
per-agent stores makes each agent refresh independently and mutually invalidate the
token until every account's refresh token dies and only re-auth recovers - a
real fleet-wide incident. Re-auth GOTCHA: `openclaw models auth login --provider
openai-codex` with no `--agent` writes to the CONFIGURED-default agent (e.g.
`clio`), NOT `main`; pass `--agent main` (or rely on a symlink redirecting the
write to canonical). Read the "↪ Model Fallback: (selected openai/gpt-5.5;
timeout)" banner as "assigned to codex, codex failed at auth refresh, fallback did
100% of the work" - not a double-run.

### Delegation, delivery, vision

**Offload coding via the agent's own harness + a git/PR wrapper, never `bash codex
exec`.** The fleet's Codex OAuth credential is in openclaw's `auth-profiles.json`
(openclaw format) and is BRIDGED INTO the codex process at spawn - it is NOT in a
codex-native `~/.codex/auth.json`. So a bash `codex exec` either can't find the
OAuth (fails) or, if you materialize a codex-native auth.json, starts an
independent token refresh that invalidates the fleet. The agent already runs on
Codex, so let it edit code itself and confine a wrapper to deterministic git/PR
mechanics that never invoke `codex`.

**Async channels need `messages.visibleReplies: "automatic"`.** The codex harness
hard-codes `sourceVisibleReplies: "message_tool"` and does NOT auto-deliver final
text (embedded runtimes like Gemini/Pi do, via `deliver()`). On a direct chatType
(e.g. Intercom DMs) with `visibleReplies` unset, codex tries to self-address the
reply, defaults to the wrong target (the bot's own id, never the conversation id),
and the reply silently never reaches the customer (no journald error - codex logs
to its own rollout sqlite). Fix: set `messages.visibleReplies: "automatic"` so
codex uses the same auto-`deliver()` path. First thing to check if any codex agent
on an async/webhook channel goes silent.

**Codex does native inbound vision.** Any agent with a codex text primary
(`openai/gpt-5.5`, which declares image input) gets inbound-image vision for free:
the plugin forwards the persisted path via `extraContext.MediaPaths` and openclaw
injects it as a native `local_image` block (proven via zero image-tool calls in
the rollout). For an explicit image TOOL, set `agents.defaults.imageModel` to the
`codex/` prefix (`codex/gpt-5.5`) - NEVER `openai/gpt-5.5` as an imageModel (that
hits the HTTP media-understanding route and TypeErrors) and never
`openai-codex/gpt-5.5` (doctor rewrites it). `imageModel` only lives under
`agents.defaults` (per-agent is dead config).

### Web search, refusals, fallback

**Web-search wiring differs for codex vs OpenRouter.** For OpenRouter model turns,
enable native search with BOTH `params.extra_body.plugins=[{id:web,engine:native}]`
AND `tools.deny += ["web_search"]` (the local web_search tool has no provider and
always fails; deny it so native is the only path). But `params.extra_body` is wired
ONLY into the openai-completions HTTP path, so it is a SILENT NO-OP on codex
runtime turns - for a codex-primary agent enable codex-native search instead
(`tools.web.search.enabled=true` + `tools.web.search.openaiCodex.enabled=true`,
uses ChatGPT OAuth, no new key). Confirm it fired in the codex rollout jsonl, not
the cron summary. Moving a codex agent OFF codex breaks codex-native search; route
its `web_search` through a managed `perplexity`/Sonar provider over the existing
OpenRouter key.

**Codex refuses competitive-intel / scraping prompts (cyber-safety classifier).**
`codex/gpt-5.5` returns a refusal flagged for "possible cybersecurity risk" on
B2B-intel / company-scraping / competitor-list tasks; openclaw can't read the
opaque reason and surfaces `reason=unknown` while codex auth is CLEAN. This recurs
for any scraping-shaped job. Pre-flighting prompts through "the same checks OpenAI
does" is INFEASIBLE (the Moderation API has no cyber category -> false confidence;
a same-model self-check hits the same classifier). Keep scraping/competitive-intel
agents on a non-codex brain (Opus + a Sonar search provider); keep codex for coding
agents.

**An empty completion counts as `candidate_succeeded` and short-circuits the
fallback chain.** A model that returns 0 tokens (e.g. a rate-limited search turn)
is recorded `candidate_succeeded ... next=none`, so the chain never cascades to a
capable later fallback and the user sees "Agent couldn't generate a response."
openclaw only auto-cascades on a 0-token completion for GPT-5-family models (an
`isGpt5ModelId` gate), with no config knob. Mitigation: reshape every
agent+cron fallback chain so non-GPT-5 models are LAST-only (swap mid-chain
non-GPT-5 entries for a cheap GPT-5-family model that cascades), enforce it in CI,
and run a watchdog on the `payloads=0 ... surfacing error to user` journald line.

### Observability gotchas

**Verifying a codex agent actually runs gpt-5.5.** The reliable probe is
`openclaw --profile main agent --agent <id> --json --message "Reply with only:
OK" > /tmp/p.json`, then read `result.meta.agentMeta.{provider,model,agentHarnessId}`:
`openai-codex` / `gpt-5.5` / `codex` = real codex; `openrouter` / `pi` = fallback
or wrong profile. False-negative traps that gave hours of bogus "codex broken"
readings: (1) omitting `--profile main` runs the BARE legacy default profile
(`/root/.openclaw/`, harness `pi`, no codex plugin) which ALWAYS falls back to
Sonnet; (2) piping the turn through `| grep`/`| tail` can close the client stdout
early and KILL the turn (`codex app-server client closed before turn completed`) -
write to a file then parse; (3) `--gateway` is NOT a flag on `openclaw agent` (it
errors and no-ops); (4) the CLI's own stderr `[model-fallback/decision]` is NOT
what the gateway did - don't trust it. Ground truth for REAL traffic is the
gateway journal, not CLI assertions: codex-dead shows `401 Unauthorized: Incorrect
API key` or `auth refresh request timed out` on the real Slack/cron lanes; their
absence plus a fresh-rotated `agents/main/.../auth-profiles.json` mtime = healthy.

**Codex usage/quota is in the rollout jsonl, not `auth-profiles.json` or `status
--usage`.** `auth-profiles.json` holds only token expiry + plan per profile (and
it's an OBJECT - iterate `.profiles | to_entries`, not `map()` over the root). The
real 5h + weekly limits live in `/root/.openclaw-<profile>/agents/<agent>/agent/codex-home/sessions/YYYY/MM/DD/rollout-*.jsonl`
as `rate_limits` (`primary` = 5h window, `secondary` = weekly, each with
`used_percent`/`resets_at`). The fleet shares one codex auth store, so a snapshot
reflects whichever account was `lastGood`. (openclaw cron `delivery.to` is a single
string, not an array - one cron per recipient.)

**Agents CANNOT perceive their own model-fallback / degraded state.** The "Model
Fallback" banner is built only on the outbound delivery path and is NEVER injected
into the agent's prompt. So a SOUL rule like "when you're degraded, defer
destructive actions / flag it" is DEAD TEXT - it cannot fire (a degraded model with
no in-context signal is exactly how a refund hallucination happened). What works:
key honesty on what the agent CAN see (the tool result - "a write counts only on
concrete success: Stripe `re_...`, admin-API 200, a logged row; on error/empty,
report not-done and @-mention, never fabricate"). A true defer-when-degraded gate
needs a mechanical layer OUTSIDE the model (a model-health check at the shell
boundary keyed on the same `reason=auth_permanent` signal a watchdog scans).

**A codex cron that self-posts via the `message` tool false-pages the cron
watchdog.** Under the codex runtime, an agent that posts its own report to Slack is
NOT credited as the cron delivery - the run keeps `delivered:false` /
`status:error` (a trailing non-fatal tool error overwrites the summary because
codex's tool isn't in openclaw's exec-like-tool set). So `delivered:false` does NOT
mean the report missed Slack; verify against the actual channel. The reliable
"agent reached its channel" signal is a non-empty `delivery.messageToolSentTo`
(recorded only after a successful message-tool send), NOT `delivered:true` or
`delivery.resolved.ok`.

**A small-model brain confabulates "tool availability blocker" / skill-missing
escalations.** A Haiku-class agent (e.g. scout) will claim a skill "isn't in my
toolset" and escalate even when `skills --agent <a> info <skill>` shows it Ready
and visible. Diagnosis: the "blocker" turn makes ZERO tool calls (a healthy run
makes many exec/web_search calls), and the gateway journal shows `[tools] read
failed: ENOENT ... /root/.openclaw/skills/<skill>/SKILL.md` - the brain `read`s the
SKILL.md at a hallucinated legacy path, hits ENOENT, and wrongly infers "tool
missing." Count exec/web_search records in the session jsonl: 0 = confabulation,
not infra. Doctrine only weakly constrains a small brain; durable fixes are a brain
upgrade or a post-boundary guard. Do not accept "forbidden workspace shadow" as the
root cause for a skill that merged green (CI's drift check would have blocked it).
