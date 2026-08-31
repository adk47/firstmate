# Upgrade runbook: openclaw 2026.7.1 → 2026.8.1 ("OpenClaw 2.0")

Status: **DRAFT — staging runs 1–2 completed 2026-08-31** on node-8
(`/opt/openclaw-stage81` runtime + `/root/.openclaw-stage81`, a fully
neutered copy of prod `-main`; neuter script `/root/neuter-stage81.sh`).
Every mechanic below marked OBSERVED was hit on that run, not inferred.
Remaining before prod: Gates C/D (real-token one-shots), M (edge device
logins), H (deploy smoke with the PR3 deploy.sh), plus the first upstream
correction release.

**Timing gate (decided 2026-08-31):** prod window opens at the EARLIER of
(a) the first 2026.8.x correction release, or (b) 7 quiet days upstream —
AND all staging gates green. Target week of 2026-09-08. 2026.8.1 shipped
2026-08-30; P1 `impact:crash-loop` issues were opened against it on
2026-08-31 (openclaw#133987, #134037). Both migrations are one-way.

## What changes in 8.1 (read before touching anything)

- **The config schema is stricter, and an invalid config blocks
  EVERYTHING (OBSERVED).** 13 keys our configs carry are schema-rejected
  (`meta.lastTouchedAt`, `browser.remoteCdp*TimeoutMs`,
  `agents.defaults.memorySearch` + its `query.hybrid`,
  `bootstrapPromptTruncationWarning`, `messages.removeAckAfterReply`,
  `messages.tts`, `commands.ownerDisplay`, `cron.maxConcurrentRuns`,
  `gateway.tailscale.resetOnExit`, `plugins.installs`, root `web`,
  `channels.slack.thread.requireExplicitMention`, per-agent
  `memorySearch`). While the config is invalid, `doctor --fix` performs
  NO state migration and every CLI command refuses. **PR #896 (draft)
  carries the full reshape — it merges only at the window because 7.1
  REJECTS the reshaped file.** Also 2.0 requires
  `agents.defaults.sessionStore.agentId` (we set `clio`) to give the
  legacy `agents/main` rows an owner — without it, migration defers per
  agent with "no unambiguous configured owner" (OBSERVED).
- **Plain `doctor` is NOT read-only (OBSERVED)** — it auto-applies "safe"
  config migrations (agents.list→entries in memory, memorySearch move,
  etc.). Deploy's rsync clobbers any live-file edit, so config shape
  lives ONLY in repo JSON (PR #896); doctor is for STATE.
- **Auth goes native-SQLite with a single shared cell (OBSERVED).** Final
  home: `<state-dir>/state/openclaw.sqlite`, table
  `config_machine_state`, rows `authProfiles.store` /
  `authProfiles.state`. `doctor --fix` imports legacy
  `auth-profiles.json`/`auth-state.json`, renames profiles
  `openai-codex:*` → `openai:*`, funnels ALL per-agent symlinked copies
  into that one cell (no per-agent fan-out — the 7.1 symlink fabric needs
  no pre-scrub), archives sources as `*.migrated-<ts>-<uuid>`, and
  records one-shot receipts (`migration_sources`/`migration_runs`) — a
  recreated legacy file does NOT re-import unless receipts are cleared.
  Per-agent `auth_profile_store` rows stay empty; agents read through to
  the shared cell. The runtime then auto-refreshes tokens in-process
  under a file lock (token-sink design; rejected refresh ⇒ loud re-auth
  flag).
- **Import preconditions, each proven by a failed staging run
  (OBSERVED)**: (1) valid config; (2) NO legacy `exec-approvals.json` in
  the state dir — its mere presence aborts the doctor pipeline BEFORE the
  auth stage with only a trailing warning line; (3) **gateways STOPPED**
  — a running gateway makes doctor refuse: "OpenClaw refused shared state
  schema mutation … another Gateway owns that state directory";
  (4) `sessionStore.agentId` set.
- **Trust the store, not the report (OBSERVED).** Doctor printed
  "Migrated 3 OpenAI Codex auth profile(s)" on a run that landed ZERO
  profiles (values failed verification). The only valid post-migration
  assertion is reading the cell (verify battery below).
- **Sessions import needs the targeted mode (OBSERVED)**: plain
  `doctor --fix` DEFERS session migration; run
  `doctor --fix --session-sqlite import --session-sqlite-all-agents`
  (gateways stopped). It writes a manifest under
  `session-sqlite-migration-runs/`, archives `sessions.json` + hot JSONL,
  compacts per-agent DBs. Startup REFUSES readiness on ANY unresolved
  legacy artifact — on staging that meant: unmigrated sessions, then an
  orphaned `credentials/slack-design-allowFrom.json` (allowFrom of the
  removed `design` agent; archive it aside).
- **Agent DB migration**: real agent DBs migrate v1 → v19 cleanly, incl.
  archived-transcript media. Our 7.1 inheritance-base shim
  (`agents/main/agent/openclaw-agent.sqlite`, the 2-table DB
  codex-auth-sync.sh created) is UNMIGRATABLE ("no schema ownership
  metadata") and must be archived aside first (OBSERVED).
- **Plugins**: install/replacement on 2.0 requires capability consent —
  deploy.sh's `plugins install` needs `--accept-capabilities` (OBSERVED:
  "Kept installed plugin codex; replacement deferred"). SDK deprecation
  gates 2026-09-01 handled in PR #893. `dist/plugin-sdk/cron-store-runtime.js`
  still exists (deploy cron import safe). support-tools loads on 2.0.
- **CLI changes that break scripts (OBSERVED)**: multi-agent installs now
  require `--agent <id>` or `--all-agents` for `skills list` and
  `sessions`; `sessions --all-agents --json` returns
  `{stores:[{agentId,path}], sessions:[…], count, totalCount, …}`;
  several CLI paths hard-fail while any configured secret provider is
  unresolvable. `sessions.json` no longer exists post-migration — any
  script reading it must move to the CLI/SQLite (PR2).
- **Fixed upstream, confirmed in dist**: compaction-on-OAuth-only
  (#95831 — fixed-form anchor present ⇒
  `patch-openclaw-codex-native-compaction.sh` RETIRES). Watchdog
  signature strings all survive EXCEPT `requireInactive` (our dist patch
  — upstream never adopted it; the 2.0 delete path has
  `expectedSessionUpdatedAt` + `prepareSessionLifecycleDrain`; re-port
  decision pends a live Gate E delete test). Mention-gate patch anchor is
  GONE (15 runtime-api files, zero `app_mention` in dist) — needs
  from-scratch re-evaluation against 2.0's channel-policy/preflight.
- **NOT fixed upstream — ours stays**: cross-state-dir credential sharing
  (#90575 open ⇒ edge strategy below); protected-Slack-thread retention
  (prune stays; wedge class survives — protected rows still uncapped,
  `:cron:` still disposable; native `cron.sessionRetention` default 24h
  helps the cron half); usage-cap account rotation (new surface =
  `auth.order.openai`); `OPENCLAW_STATE_DIR` pin (Gate J passed WITH the
  pin — 1,219 catalog lines; pin-required test still open).
- **2.0 secrets audit** flags our 22 plaintext Slack tokens in config
  (warn-only). Post-upgrade hardening candidate: SecretRefs / team store.
- **Staging run 2 (real-access-token one-shot) — the layered path to a
  working codex call on 2.0 (each stage OBSERVED)**: unresolved secret
  providers hard-fail the CLI → the codex PLUGIN must match the runtime
  (the carried-over 7.1 plugin loads but the harness registers nothing;
  install `@openclaw/codex@2026.8.1 --force --pin --accept-capabilities`;
  2.0 plugin installs live under
  `<state-dir>/npm/projects/openclaw-codex-*/node_modules/@openclaw/codex`)
  → each profile's `provider` field must be exactly `openai` (a
  wrong-provider profile is silently "unusable" → "Explicit auth order
  for openai has no usable profiles", #133175) → authored
  `models.providers.openai.models[].api: "openai-completions"` makes the
  codex harness refuse the route ("Codex cannot reproduce the prepared
  provider route") — PR #896 drops the `api` field (openai provider
  ONLY; openrouter's stay) → auth then reads `status=usable`.
- **BLOCKER (root cause = our own 7.1 sync): hydra holds NO genuine OIDC
  id token.** `codex-auth-sync.sh:282` wrote `id_token: $access` into
  every codex-home (verified byte-identical, access-shaped claims);
  canonical never carried one. 7.1's codex tolerated it; **2.0's codex
  0.151.0 validates and rejects: "failed to set external auth: invalid
  ID token format"** (the plugin passes `credentialExtra.idToken`). A
  genuine id token is minted only by a real OAuth refresh (the token
  response carries `id_token` — our refresher DISCARDS it) or a device
  login. Post-migration prod would hit the same failure until a real
  refresh stores one ⇒ the window gains an explicit mint step (Phase 4)
  and Gate C completes pre-window by capturing the id_token at the next
  scheduled refresh (Wed 2026-09-02 04:05 UTC) and re-running the
  one-shot with it.

## Target auth architecture (decided 2026-08-31)

- **main: full native adoption.** Shared cell is authoritative; fan-out
  retired; per-agent `codex-home/auth.json` archived at cutover (harness
  precedence: injected ordered profiles first); native auto-refresh is
  the SOLE refresher — `codex-token-refresh.timer` disabled permanently
  BEFORE first 2.0 boot. `codex-auth-sync.sh`/`ensure-codex-auth.sh`
  retire in favor of read-only `codex-auth-invariants.sh` (PR2).
- **edge: independent OAuth sessions per state dir (Option B).** Separate
  device logins per state dir ⇒ separate refresh chains ⇒ the
  cross-process refresh race ceases structurally;
  `ensure-codex-refresh-lock-shared.sh` retires. Fallback Option A
  (access-token mirror) pre-written, disabled; trigger if Gate M shows
  sibling-session invalidation.
- **Rotation** keeps `/var/lib/hydra/codex-active-account`; actuator
  surface becomes `auth.order.openai` (both repo configs, one PR).
  Evaluate 2.0's native usage-limit failover in staging first.

## Phase 0 — staging gates (status 2026-08-31)

| Gate | Status |
|---|---|
| A auth import | **PASS (mechanics)** — cell populated, `openai:*` rename, refresh tokens in shared cell only, receipts recorded. Wrinkle: a repeated import created variant `openai:chatgpt-<email>` ids ⇒ prod assertion is EXACTLY 3 `openai:<email>` keys; prune extras with `models auth logout`. Real-token verify = Gate C/D. |
| B fail-closed | **PASS** — `AUTH_PROFILE_MIGRATION_REQUIRED` observed at startup + per-agent hydration (string added to watchdog in PR2). |
| C codex e2e / C2 openai-plugin / C3 quota probe | **PARTIAL** — one-shot ran: full auth chain verified to the app-server (`status=usable`); FINAL HOP blocked by the missing-genuine-id-token finding (see above). Completes after the Wed 2026-09-02 04:05 UTC refresh captures a real `id_token`. C2: the `openai` plugin stayed absent throughout — native OAuth works without it (keep disabled). C3: static half PASS — `account/rateLimits/read` (+`/updated`) present in codex 2026.8.1; live probe pends a real token. |
| D native refresh | OPEN (needs real credentials; verify single-refresh-under-lock + write-back). |
| E sessions | **PASS (closed)** — import proven, and live `sessions.delete` tested on 2.0: `requireInactive` is schema-REJECTED (`unexpected property`), baseline delete works (`ok:true` + `.zst` transcript archive), the stale-`expectedSessionUpdatedAt` race returns `changed before deletion. Retry.` (prune grep still matches), and active work is natively protected (`could not safely stop before deletion`, retryable, via `runExclusiveSessionLifecycleMutation` + lifecycle drain). Prune script drops `requireInactive` on ≥2026.8 (fix on #897). |
| F routes/config | **PASS** — both repo configs `Config valid` on 2026.8.1 (PR #896); cron payloads/stored-session migration observed via doctor. |
| G plugins | PARTIAL — support-tools loads; codex/slack install with `--accept-capabilities` pending PR3 deploy run. |
| H deploy | **REFRAMED + COVERED** — deploy.sh is prod-hardwired (rsync targets, systemd units), so a staging "smoke deploy" would test a neutered fork, not the real path. Pre-window coverage: PR3 (#899) ships the changes with shellcheck + bats + full regression sweep, and the NEW Step 4d.6 gate makes the window deploy itself fail-loud BEFORE touching state if Phase 2 scrubs are incomplete — the window's first phase IS the smoke test, with rollback intact. Mint script's live sentinel-refusal path verified against the staging cell (refuses derived stores, store untouched, RC=1). |
| I signatures | **PASS** (all strings in dist; `requireInactive` absent ⇒ patch decision in E). |
| J state-dir pin | **PASS with pin** (1,219 skills); pin-required test OPEN. |
| K dist patches | **CLOSED — all three RETIRE on 2.0**: compaction (#95831 in dist), inactive-delete (native drain + compare-guard, see Gate E), mention-gate (**natively upstreamed** — @openclaw/slack 2026.8.1 treats `source === "app_mention"` as an explicit mention in pipeline.runtime, exactly what our patch injected). Only inactive-session-delete is live-wired in deploy.sh (the mention-gate patch was already unwired at 2026.4.2+ — its file is legacy cruft); PR3 gates it `< 2026.8` and deletes the compaction patch outright; remove the remaining patch files post-window. |
| L lane wedge | Strings verified; watchdog stays regardless. |
| M edge Option B | Rehearsal COMPLETE (staging run 3): plugin-FIRST ordering proven (legacy-key config → install slack+codex 2026.8.1 `--accept-capabilities` → re-migrate key → doctor rc=0 → session import → boot healthy, support bound, intercom sessions intact). Two lessons: (a) new-form config + old plugin = hard-invalid AND `plugins install` refuses under invalid config — the wedge recovery is revert-key → install → re-migrate (prod avoids it by deploying via deploy.sh: Step 1 validates shape only, plugin installs at 4d.5 precede the first schema validation at restart); (b) edge's derived sentinel auth files DO import into the cell if not scrubbed — the Phase 2 edge-scrub is load-bearing. OPEN: the 3 real device logins at the window. |
| N tool-policy vs codex harness | **CLOSED** — 2.0 refuses tool-restricted conversations on a harness without `conversationToolPolicySupport: "exact"`; observed on support (the #408 exec deny) while edge staging ran the stale 7.1 codex plugin; codex 2026.8.1 declares `"exact"` and the refusal disappears after upgrade (0 occurrences post-reboot). Deploy's per-profile plugin install covers prod; the deny itself survives doctor's list→entries rewrite (`agents.entries.support.tools.deny`). |

## Phase 1 — window open, refresher off, cold archive

```bash
# Paste this WHOLE block: it runs as one fail-fast unit and ABORTS on the
# first failing command (set -euo pipefail) instead of scrolling past it.
bash -euo pipefail <<'RUNBOOK_BLOCK'
/opt/hydra/scripts/hydra-maintenance.sh start "openclaw 2026.8.1 upgrade" --ttl 3h
# Retire the refresher FAIL-CLOSED: every step below must succeed, and BOTH
# units must PROVE inactive before anything is archived or migrated — a
# just-triggered oneshot can otherwise mutate credentials mid-archive.
systemctl disable --now codex-token-refresh.timer \
  || { echo "REFUSING: could not disable codex-token-refresh.timer"; exit 1; }
systemctl stop codex-token-refresh.service \
  || { echo "REFUSING: could not stop codex-token-refresh.service"; exit 1; }
for u in codex-token-refresh.timer codex-token-refresh.service; do
  for i in $(seq 1 30); do
    st=$(systemctl is-active "$u" || true)   # is-active exits nonzero for inactive — read the WORD
    case "$st" in inactive|dead|failed) break ;; esac
    sleep 2
  done
  case "$(systemctl is-active "$u" || true)" in
    inactive|dead|failed) ;;
    *) echo "REFUSING: $u still reports '$(systemctl is-active "$u" || true)'"; exit 1 ;;
  esac
done
for d in /root/.openclaw-main /root/.openclaw-edge; do
  locks=$(find "$d"/locks/oauth-refresh -type f 2>/dev/null | wc -l)
  [ "$locks" -eq 0 ] || { echo "REFUSING: live oauth-refresh lock in $d — a refresh is in flight"; exit 1; }
done
systemctl stop openclaw-gateway-main openclaw-gateway-edge
while pgrep -f "[o]penclaw/dist/index.js" >/dev/null; do sleep 2; done
ts=$(date -u +%Y%m%dT%H%M%SZ)
tar -C /root -czf /root/openclaw-state-pre81-${ts}.tar.gz .openclaw-main .openclaw-edge \
  || { echo "REFUSING: archive creation failed — do NOT proceed"; exit 1; }
sha256sum /root/openclaw-state-pre81-${ts}.tar.gz > /root/openclaw-state-pre81-${ts}.tar.gz.sha256
ls -lh /root/openclaw-state-pre81-${ts}.tar.gz*
RUNBOOK_BLOCK
```

Gateways stay stopped through Phase 4 — doctor REFUSES state mutation
while one runs (observed).

## Phase 2 — pre-doctor scrub (per state dir; every item observed to block)

```bash
# Paste this WHOLE block: it runs as one fail-fast unit and ABORTS on the
# first failing command (set -euo pipefail) instead of scrolling past it.
bash -euo pipefail <<'RUNBOOK_BLOCK'
ts=$(date -u +%Y%m%dT%H%M%SZ)
for d in /root/.openclaw-main /root/.openclaw-edge; do
  # (a) the unmigratable codex-auth-sync shim DB:
  [ -f $d/agents/main/agent/openclaw-agent.sqlite ] && \
    mv $d/agents/main/agent/openclaw-agent.sqlite{,.pre81-$ts}
  # (b) legacy exec approvals — VALUE-FREE verification (the file carries a
  # live socket.token; cat-ing it into a recorded SSH/tmux session leaks a
  # reusable credential). Assert the shape is the expected empty maps, print
  # only counts, then archive; non-empty maps REFUSE for human review:
  if [ -f $d/exec-approvals.json ]; then
    jq -e '(.defaults | length) == 0 and (.agents | length) == 0' $d/exec-approvals.json >/dev/null \
      || { echo "REFUSING: $d/exec-approvals.json carries non-empty defaults/agents ($(jq -r '[(.defaults|length),(.agents|length)] | join("/")' $d/exec-approvals.json) entries) — review before archiving (do NOT print the file)"; exit 1; }
    mv $d/exec-approvals.json{,.pre81-$ts}
  fi
  # (c) orphaned allowFrom of removed agents (design observed on main):
  for f in $d/credentials/slack-*-allowFrom.json; do
    id=$(basename "$f" | sed "s/slack-\(.*\)-allowFrom.json/\1/")
    jq -e --arg id "$id" ".channels.slack.accounts[\$id]" $d/openclaw.json >/dev/null 2>&1 \
      || { mv "$f" "$f.pre81-$ts"; echo "orphan archived: $f"; }
  done
  # (d) per-agent codex-home auth files (harness must use injected profiles):
  find $d -path "*/codex-home/auth.json" -exec mv {} {}.pre81-$ts \;
done
# Per-agent auth-profiles.json SYMLINKS stay — doctor funnels them into the
# shared cell and archives them (observed; no fan-out).
# main: canonical auth-profiles.json stays IN PLACE (it is the import source).
# edge: archive ALL auth JSON (derived, sentinel-bearing — import nothing):
for f in /root/.openclaw-edge/agents/*/agent/auth-profiles.json \
         /root/.openclaw-edge/agents/*/agent/auth-state.json; do
  [ -e "$f" ] && mv "$f" "$f.pre81-$ts"
done
RUNBOOK_BLOCK
```

## Phase 3 — deploy runtime + config

From `/var/lib/hydra-release/repo` (never `/opt/hydra`), with PR #896 +
PR3 merged: `./scripts/deploy.sh --target all`. Deploy handles Node gate,
`openclaw@2026.8.1`, plugins `--force --pin --accept-capabilities`,
config sync, cron import, restarts held for the window.

## Phase 4 — doctor migration (gateways stopped; main first)

```bash
# Paste this WHOLE block: it runs as one fail-fast unit and ABORTS on the
# first failing command (set -euo pipefail) instead of scrolling past it.
bash -euo pipefail <<'RUNBOOK_BLOCK'
# MAIN:
export OPENCLAW_STATE_DIR=/root/.openclaw-main
openclaw --profile main doctor --fix                                   # auth + routes + agent DBs
openclaw --profile main doctor --fix --session-sqlite import --session-sqlite-all-agents
# VERIFY THE STORE, NOT THE REPORT:
node --experimental-sqlite -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync("/root/.openclaw-main/state/openclaw.sqlite",{readOnly:true});
const v=JSON.parse(db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store").value_json);
const ks=Object.keys(v.profiles).sort(); console.log(ks);
const expected=["openai:aaron@muso.ai","openai:aarondkaufman@gmail.com","openai:aaronkaufman@me.com"].sort();
// IDENTITY-EXACT: three wrong openai:* keys with refresh tokens would pass a
// count+shape check — compare the sorted key SET against the expected accounts.
if (JSON.stringify(ks)!==JSON.stringify(expected)) { console.error("account identity mismatch"); process.exit(1); }
if (!ks.every(k=>v.profiles[k].refresh)) { console.error("missing refresh token"); process.exit(1); }
// wrong-provider profiles are silently UNUSABLE (staging run 2) — require exactly "openai":
if (!ks.every(k=>v.profiles[k].provider==="openai")) { console.error("wrong provider field on a profile"); process.exit(1); }'
# session manifest: ls /root/.openclaw-main/session-sqlite-migration-runs/
# MINT the missing id tokens BEFORE first boot — EXECUTE, do not just read:
# one controlled refresh per profile writes access+refresh+idToken into the
# cell (the store otherwise holds no genuine id_token — see BLOCKER above —
# and codex fails "invalid ID token format"). Also proves Gate D-positive.
for pid in openai:aaron@muso.ai openai:aarondkaufman@gmail.com openai:aaronkaufman@me.com; do
  /opt/hydra/scripts/lib/codex-mint-idtoken.sh --state-dir /root/.openclaw-main --profile-id "$pid" \
    || { echo "REFUSING: mint failed for $pid — do not boot; investigate before any retry"; exit 1; }
done
# POST-MINT GATE — prove every expected profile now carries an idToken:
node --experimental-sqlite -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync("/root/.openclaw-main/state/openclaw.sqlite",{readOnly:true});
const v=JSON.parse(db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store").value_json);
for (const k of ["openai:aaron@muso.ai","openai:aarondkaufman@gmail.com","openai:aaronkaufman@me.com"]) {
  const p=v.profiles[k];
  if (!p || !p.idToken || !p.refresh) { console.error("post-mint gate FAILED for "+k); process.exit(1); }
}
console.log("post-mint gate OK: all three profiles carry idToken+refresh");'
systemctl start openclaw-gateway-main
# verify battery: version pins; /proc state-dir pin; skills list --agent clio
# non-empty; codex pong (clio); codex-auth-invariants.sh clean; watchdogs quiet.

# EDGE (auth starts empty by design):
export OPENCLAW_STATE_DIR=/root/.openclaw-edge
openclaw --profile edge doctor --fix
openclaw --profile edge doctor --fix --session-sqlite import --session-sqlite-all-agents
systemctl start openclaw-gateway-edge
RUNBOOK_BLOCK
```

Doctor's one-shot receipts mean a botched import cannot simply be re-run:
restore the archived `*.migrated-*` source, clear the matching
`migration_sources`/`migration_runs` rows (staging-rehearsed), and re-run
with gateways stopped.

## Phase 5 — edge device logins (Option B) + close

3 × `openclaw --profile edge models auth login --provider openai` (one
per account); `models auth list` = 3 `openai:*` profiles; Caroline
answers in Intercom; `hydra-maintenance.sh stop`. Keep the archive ≥ 7
days; 48h quiet watchdogs before trusting steady state.

## Rollback

```bash
# Paste this WHOLE block: it runs as one fail-fast unit and ABORTS on the
# first failing command (set -euo pipefail) instead of scrolling past it.
bash -euo pipefail <<'RUNBOOK_BLOCK'
systemctl stop openclaw-gateway-main openclaw-gateway-edge
scripts/downgrade-openclaw-runtime.sh          # extended for 8.1 -> 7.1 (PR3)
# PROVE the archive is complete, checksum-intact, and actually EXTRACTS
# (into a temp dir) BEFORE deleting anything — a partial tar still ls-es
# fine, and a wrong <ts> discovered after rm -rf leaves nothing to restore:
sha256sum -c /root/openclaw-state-pre81-<ts>.tar.gz.sha256 \
  || { echo "REFUSING: archive checksum mismatch"; exit 1; }
tmp=$(mktemp -d /root/pre81-restore.XXXXXX)
tar -C "$tmp" -xzf /root/openclaw-state-pre81-<ts>.tar.gz \
  || { echo "REFUSING: archive does not extract"; rm -rf "$tmp"; exit 1; }
for d in .openclaw-main .openclaw-edge; do
  [ -s "$tmp/$d/openclaw.json" ] && [ -e "$tmp/$d/state/openclaw.sqlite" -o -e "$tmp/$d/agents" ] \
    || { echo "REFUSING: extracted $d is missing critical trees"; rm -rf "$tmp"; exit 1; }
done
rm -rf /root/.openclaw-main /root/.openclaw-edge
mv "$tmp/.openclaw-main" /root/.openclaw-main && mv "$tmp/.openclaw-edge" /root/.openclaw-edge
rmdir "$tmp"
systemctl enable --now codex-token-refresh.timer
systemctl start openclaw-gateway-main openclaw-gateway-edge
RUNBOOK_BLOCK
```

**Any native refresh consumed post-upgrade spent the archived single-use
refresh tokens** — expect `codex-reauth.sh` device logins after a
rollback. `doctor --session-sqlite restore` is only for a partial
session-store downgrade while STAYING on 2.0.

## Post-upgrade invariants

- Refresh tokens exist ONLY in each profile's shared cell
  (`config_machine_state.authProfiles.store`); exactly 3 `openai:*`
  profiles per profile store; zero `openai-codex:*` anywhere; the RUNTIME
  is the sole refresher; the twice-weekly timer stays disabled forever.
- No `codex-home/auth.json` carries credentials; nothing reads
  `auth-profiles.json` (PR2 rewrites all consumers).
- `OPENCLAW_STATE_DIR` pins unchanged + asserted via `/proc` (unless the
  pin-required test proves it obsolete — then removed deliberately).
- Session budgets unchanged (10000 / 8gb / 6gb); budget guard reads
  SQLite; `cron.sessionRetention` native at default 24h.
