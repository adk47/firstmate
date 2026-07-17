# Upgrade runbook: openclaw 2026.6.1 → 2026.7.1

Staging-validated 2026-07-14 on node-8 (isolated install at `/opt/openclaw-stage71`
against a neutered copy of the main profile's state). Every trap below was
OBSERVED on that run, not inferred. Operator: run the phases in order, in a
low-traffic window (deploy restarts kill in-flight Caroline QA/apply runs —
respect the `--safe` drain semantics from PR #674).

## What changes in 7.1 (read before touching anything)

- **Auth is SQLite-first.** The runtime reads codex auth from
  `agents/main/agent/openclaw-agent.sqlite` (`auth_profile_store` row
  `'primary'` — the hardcoded inheritance base) and from each agent's
  `codex-home/auth.json` (the native codex app-server store, which is what
  actually authenticates model calls). `auth-profiles.json` is NEVER read at
  runtime; the 6.1 symlink fabric is inert. Our canonical JSON remains the
  source of truth for OUR tooling — `scripts/lib/codex-auth-sync.sh` fans the
  ACCESS token out to both runtime surfaces (refresh token stays ONLY in
  canonical; single-refresher invariant).
- **`plugins.allow` is ignored.** Bundled plugins (`openai`, `elevenlabs`)
  load despite the allowlist; the `openai` plugin hijacks provider `openai`
  onto the api-key route. The repo configs now carry explicit
  `plugins.entries.openai/elevenlabs = {enabled:false}` — do not remove them.
- **The codex OAuth route moved.** Working OAuth = websocket
  `wss://api.openai.com/v1/responses` with a ChatGPT Bearer token. api-key
  mode = HTTP to the same path. `chatgpt.com/backend-api/…` is GONE — do not
  use the old URL tell to diagnose (#90925 lore predates this).
- **`doctor --fix` is a trap for auth.** Its JSON→SQLite migration fans the
  profile into EVERY agent DB (single-use refresh token × N copies = the
  2026-05-29 storm) and renames profiles `openai-codex:*` → `openai:*`. NEVER
  run it for auth migration — `codex-auth-sync.sh` replaces it.
- **First-boot doctor floats the codex plugin** to the runtime version. The
  pin (codex-version.sh) is now LOCKSTEP 2026.7.1, so this is convergent, not
  a fight.
- **Node floor**: openclaw 2026.7.1 requires Node >= 22.22.3 (deploy.sh now
  gates on this and fails loud).
- Cron store, memory indexes, update-check state auto-migrate to SQLite on
  first touch (one-way). `dist/plugin-sdk/cron-store-runtime.js` still exists
  (deploy.sh cron import unaffected). Memory indexes move INTO per-agent
  DBs — expect a reindex pause on edge first boot
  (`openclaw-edge-reindex-on-start.sh` heals it).

## Phase 0 — prerequisites (before the window)

1. PR with the version bump merged (deploy.sh `OPENCLAW_VERSION=2026.7.1`,
   runtime-aware codex-version.sh, config plugin disables, codex-auth-sync.sh).
   NOTE: the merge-triggered auto-deploy will FAIL at Step 4c.5's Node gate
   until step 2 below is done — that is expected and harmless (the gate fires
   BEFORE any runtime/plugin mutation). The merge→upgrade window is safe by
   construction: codex-version.sh resolves the pin against the INSTALLED
   runtime, so pre-upgrade restarts keep healing codex to 2026.5.27 on the
   6.1 core.
2. **Upgrade Node on node-8** to the newest 22.x (>= 22.22.3):
   ```bash
   node --version   # confirm < 22.22.3 first
   # via the box's node install method (nodesource apt / n / manual tarball)
   # then confirm:
   node --version && npm --version
   ```
   Do this BEFORE deploying — deploy.sh refuses to install 2026.7.1 on old Node.
3. **Session inventory check** (the staging run saw 7.1's session cap delete
   freshly-created sessions on a state dir with thousands of legacy sessions):
   ```bash
   for p in main edge; do jq length /root/.openclaw-${p}/agents/*/sessions/sessions.json 2>/dev/null | sort -rn | head -3; done
   ```
   If any agent holds hundreds of entries, prune with the native
   `session.maintenance` lever (or archive the oldest `sessions.json` entries)
   before the bump.

## Phase 1 — cold rollback archive (the ONLY rollback path)

The 6.x→7.x state migrations are one-way. Open a maintenance window FIRST — before
stopping anything — so the autonomic watchdogs stand down; otherwise the 2-min
`openclaw-watchdog` restarts the gateways mid-archive (it corrupted the first
archive on this very upgrade) and the fleet's alarms page for a fleet that is down
on purpose. Then stop BOTH gateways:

```bash
/opt/hydra/scripts/hydra-maintenance.sh start "openclaw 7.1 upgrade" --ttl 2h   # fleet-health watchdogs stand down; flag self-expires on TTL
systemctl stop openclaw-gateway-main openclaw-gateway-edge
# The archive races drains AND healers: #674 --safe drain has no deadline, so a
# mid-model-call session can keep a gateway alive minutes after `systemctl stop`
# returns, and a lingering process still writing state corrupts the tar
# ("file changed as we read it" = tar exit 1). Archive ONLY once NO gateway process
# survives. The [o]penclaw bracket stops the pattern matching the grep/ssh shell's
# OWN cmdline — a plain pgrep/pkill -f self-matches, and pkill would kill your SSH
# session (ssh exit 255):
while pgrep -f "[o]penclaw/dist/index.js" >/dev/null; do echo "waiting for gateway processes to exit..."; sleep 2; done
ts=$(date -u +%Y%m%dT%H%M%SZ)
tar -C /root -czf /root/openclaw-state-pre71-${ts}.tar.gz \
  .openclaw-main .openclaw-edge
ls -lh /root/openclaw-state-pre71-${ts}.tar.gz   # sanity: non-trivial size
```

Keep gateways stopped through Phase 2–3 (the window continues).

The `hydra-maintenance start` above is what keeps the healers off your back for the
whole window — it supersedes the old per-window cron-file shuffle. Manual fallback
only if the helper is ever unavailable — move aside ONLY the FLEET-HEALTH watchdogs
(the same set the flag guards), and LEAVE the business/prod ones running:

- `/etc/cron.d` to move aside: `openclaw-watchdog`, `codex-keepalive`,
  `cron-health-watchdog`, `fallback-swallow-watchdog`, `stuck-lane-watchdog`,
  `caroline-rag-index-watchdog`.
- timers to stop: `codex-token-refresh.timer` (**restarts BOTH gateways** — the exact
  mid-archive corruption this guards against; do NOT forget it), `hydra-peer-labels.timer`,
  `intercom-intake-watchdog.timer`.
- LEAVE RUNNING (business/prod — a fleet window must not blind you to a real prod
  incident or sales lead): `ads-inquiry-watchdog`, `merge-landing-watchdog`,
  `prod-log-alert-watchdog`, `stale-ticket-watchdog`, `intercom-data-complaint-watchdog.timer`.

Restore the moved/stopped units after. With the flag you should never need this — and
note `hydra-peer-labels` runs the openclaw CLI, which can leave an orphan gateway
running OUTSIDE systemd (unit reads inactive while the process runs).

## Phase 2 — deploy the runtime + config

> **Trap (observed 2026-07-14):** do NOT run `cd /opt/hydra && ./scripts/deploy.sh`.
> `/opt/hydra` is the rsync TARGET and has no `.git`, so deploy.sh's Step 4a drift
> classifier exits rc=4. Deploy via the **GitHub Actions run** (the self-hosted
> runner checks out a real repo) or from the dedicated checkout at
> `/var/lib/hydra-release/repo`. The post-deploy smoke can also race main's first
> 7.1 boot (migrations) — a smoke FAIL on `cron list` right after restart may just
> be a slow boot, so re-run the smoke before believing it.

```bash
# From a REAL git checkout (never /opt/hydra) — e.g. the release checkout:
cd /var/lib/hydra-release/repo && git fetch && git reset --hard origin/main
./scripts/deploy.sh --target all
```

deploy.sh handles: Node floor gate, `npm install -g openclaw@2026.7.1`,
`@openclaw/{slack,codex}@2026.7.1` per profile (`--force --pin`), config sync
(with the new plugin disables), cron SQLite import, restarts.

## Phase 3 — auth migration (replaces doctor --fix; do BEFORE first start if
deploy did not already restart, otherwise immediately after)

```bash
/opt/hydra/scripts/lib/codex-auth-sync.sh --force   # --force: first run may race the version gate if openclaw was just installed
/opt/hydra/scripts/lib/codex-auth-sync.sh --check   # must print "clean"
systemctl restart openclaw-gateway-main openclaw-gateway-edge
```

This seeds each profile's main-agent SQLite row from the canonical JSON
(profiles renamed to `openai:*`), deletes any per-agent auth rows, and writes
chatgpt-mode `codex-home/auth.json` (access token only) for every agent.

> **Trap (observed 2026-07-14):** if a gateway crash-loops on start with
> `startup migrations did not complete cleanly`, a stale foreign-harness codex
> sidecar is blocking the 7.1 startup migration — a
> `<session>.jsonl.codex-app-server.json` "owned by agent harness pi" (seen on the
> finance agent). Fix: `mv` the offending sidecar file(s) aside (they are preserved
> in the Phase 1 archive) and restart. Do NOT run `openclaw doctor --fix` — its
> auth fan-out is the 2026-05-29 single-use-refresh-token storm (see "What changes
> in 7.1").

## Phase 4 — verify (per profile, main first, then edge)

```bash
# 1. Runtime + pins
openclaw --version                                    # 2026.7.1
openclaw --profile main plugins list --json | jq -r '.plugins[] | select(.id=="codex" or .id=="openai") | "\(.id) \(.version) \(.enabled)"'
#   codex 2026.7.1 true / openai … disabled-or-absent
# 2. Guards
/opt/hydra/scripts/lib/ensure-codex-auth.sh --check           # delegates to sync; clean
/opt/hydra/scripts/lib/ensure-codex-refresh-lock-shared.sh --check
/opt/hydra/scripts/lib/ensure-codex-version-pinned.sh --check
# 3. State-dir pin (managed skills) — check the RUNNING daemon's env
pid=$(systemctl show -p MainPID --value openclaw-gateway-main)
tr '\0' '\n' < /proc/$pid/environ | grep OPENCLAW_STATE_DIR   # /root/.openclaw-main
openclaw --profile main skills list | head -3                 # catalog non-empty
# 4. Codex OAuth end-to-end (THE test that matters)
openclaw --profile main agent --agent clio -m "Reply with the single word: pong" --json
#   expect a completion from openai/gpt-5.5; on failure grep journal for
#   "invalid_api_key" (api-key route = auth.json regressed to apikey mode)
# 5. Edge: Caroline answers in Intercom; RAG reindex completed
journalctl -u openclaw-gateway-edge --since -10m | grep -i "memory\|index" | tail -5
```

Once verify passes, close the maintenance window so the watchdogs re-arm:

```bash
/opt/hydra/scripts/hydra-maintenance.sh stop
```

(If you forget, the flag self-expires after its TTL and every watchdog re-arms on
its own — fail-safe by design; `/run` is tmpfs so a reboot also clears it.)

Keep the rollback archive until the watchdogs have been quiet for 48h;
delete nothing before then.

## Rollback

```bash
systemctl stop openclaw-gateway-main openclaw-gateway-edge
scripts/downgrade-openclaw-runtime.sh   # runtime + plugins back to 6.1/5.27
rm -rf /root/.openclaw-main /root/.openclaw-edge
tar -C /root -xzf /root/openclaw-state-pre71-<ts>.tar.gz
systemctl start openclaw-gateway-main openclaw-gateway-edge
```

The JSON auth files inside the archive are intact — the 6.1 symlink fabric
resumes as-is (`ensure-codex-auth.sh` runs legacy mode on a 6.1 runtime).

## Post-upgrade invariants (what the guards now enforce)

- Real codex refresh tokens exist ONLY in
  `/root/.openclaw-main/agents/main/agent/auth-profiles.json` (canonical).
  `codex-oauth-refresh.sh` (Sun+Wed timer) is the SOLE refresher and re-syncs
  derived stores after each rotation.
- Every agent's `codex-home/auth.json`: `auth_mode:"chatgpt"`, current access
  token, sentinel refresh. `--check` pages via the watchdog on drift.
- No per-agent `auth_profile_store` rows outside `agents/main/agent`.
- If ElevenLabs TTS broke (messages.tts): 7.1 may have moved TTS into the now
  explicitly-disabled `elevenlabs` plugin — re-enable that single entry and
  restart; the openai entry must STAY disabled.
