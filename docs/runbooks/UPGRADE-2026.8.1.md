# Upgrade runbook: openclaw 2026.7.1 → 2026.8.2 ("OpenClaw 2.0")

Status: **DRAFT — staging runs 1–2 completed 2026-08-31** on node-8
(`/opt/openclaw-stage81` runtime + `/root/.openclaw-stage81`, a fully
neutered copy of prod `-main`; neuter script `/root/neuter-stage81.sh`).
Every mechanic below marked OBSERVED was hit on that run, not inferred.
Remaining before prod: Gates C/D (real-token one-shots), M (edge device
logins), H (deploy smoke with the PR3 deploy.sh), plus the first upstream
correction release.

**Timing gate — TRIGGER FIRED 2026-09-01.** The window opened at the
EARLIER of (a) the first 2026.8.x correction release or (b) 7 quiet days
upstream: **2026.8.2 published 2026-09-01T16:19Z**, with `@openclaw/codex`
and `@openclaw/slack` in lockstep. **The target is now 2026.8.2, not 8.1**
(PR #899). Both migrations are still one-way, and the cutover remains an
explicit human go.

**What 2026.8.2 changes for this runbook (re-validated 2026-09-01 on FRESH
copies of BOTH prod state dirs — real 7.1 state → 8.2, private prefix
`/opt/openclaw-stage82`, 12-item neuter; the 8.1 staging dirs could not
retest the doctor path because they were already migrated):**

- **The `exec-approvals.json` doctor ABORT is fixed** (openclaw#118282,
  #133952). Doctor now imports the approvals into shared SQLite, removes the
  JSON after recording the migration, and runs the auth stage in the SAME
  pass. Phase 2 no longer archives that file — see (b) there. This both
  removes a step and PRESERVES the approvals.
- **Session import folded into plain `doctor --fix`**; the targeted
  `--session-sqlite` command is kept below purely as a verifying no-op.
  Fidelity checked against live prod: 1,735 sessions imported vs 1,742 live
  keys (delta = tiny stores + prod drift). A manifest's "planned/completed
  moves" counts TRANSCRIPT moves, not sessions — 3,516 moves for an agent
  with 130 sessions is normal, NOT loss.
- **NEW mandatory step**: doctor does not clear the per-agent
  `auth_profile_store` rows our 7.1 fan-out wrote — see Phase 4.
- Unchanged from the 8.1 validation: the 13 rejected config keys,
  plugin-first ordering, `--accept-capabilities`, `"exact"` tool-policy
  support, absent `requireInactive`, `account/rateLimits/read`,
  `cron-store-runtime.js`, and the plugin-SDK export surface.

2026.8.1 shipped 2026-08-30; of the two P1 `impact:crash-loop` issues opened
against it, openclaw#134037 is CLOSED (fixed) and #133987 remains open but is
GitHub-Copilot model discovery, which hydra does not use.

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
  (OBSERVED)**: (1) valid config; (2) `exec-approvals.json` handling is
  VERSION-SPECIFIC — on 2026.8.1 its mere presence aborted the doctor
  pipeline BEFORE the auth stage with only a trailing warning line (so it
  had to be archived first); on **2026.8.2, the target, it is IMPORTED by
  doctor and must be LEFT IN PLACE** — archiving it there discards the
  approvals the upgrade would otherwise preserve (Phase 2 (b) below is the
  authoritative step); (3) **gateways STOPPED**
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
  install `@openclaw/codex@2026.8.2 --force --pin --accept-capabilities`;
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
| C codex e2e / C2 openai-plugin / C3 quota probe | **PASS (2026-09-04, on 2026.8.2, real id token from #898's Wed capture)** — clio answered PONG in 3.4s: `provider=openai model=gpt-5.6-sol agentHarnessId=codex credentialSource.kind=profile`, cost 0, no fallback line, no id-token error; cto answered PONG through read-through inheritance from the shared cell; zero `codex-home/auth.json` re-created and zero canonical tokens found anywhere on disk after the run (sha-compared, value-free). History: the earlier one-shot ran: full auth chain verified to the app-server (`status=usable`); FINAL HOP blocked by the missing-genuine-id-token finding (see above). Completes after the Wed 2026-09-02 04:05 UTC refresh captures a real `id_token`. C2: the `openai` plugin stayed absent throughout — native OAuth works without it (keep disabled). C3: static half PASS — `account/rateLimits/read` (+`/updated`) present in codex 2026.8.1; live probe pends a real token. |
| D native refresh | **NEGATIVE HALF PASS (2026-09-04, 8.2)** — head profile forced past expiry with the SENTINEL refresh: the runtime logged `[agent/embedded] auth profile failure state updated: … provider=openai reason=auth window=cooldown reused=false`, wrote `cooldownReason:"auth"` for that profile into `authProfiles.state`, rotated to the next `auth.order` profile (the pong still succeeded), and did NOT rewrite any refresh token. That log line is 2.0's loud signature for a dead refresh chain — add it to the watchdog post-window. **POSITIVE half** (a real refresh under lock + write-back) is deliberately NOT rehearsed on staging (single-refresher invariant); it is executed at the window by the Phase 4 mint loop, whose post-mint gate asserts the write-back. |
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
# DISK GATE FIRST — before maintenance, before the workflow is disabled, before
# anything is stopped: a low-space refusal must leave production RUNNING and
# the CI deploy enabled, not down with the workflow off (QA finding).
# (Measured on the 2026-09-04 rehearsal: 50G of -main -> 17G archive
# in 15m36s; restore = verify + extract-to-tmp + swap in 4m08s). Both prod dirs
# are ~70G, so expect a ~25G archive and ~25 min here, and a rollback later needs
# the FULL 70G extracted into a temp dir WHILE the live dirs still exist. Refuse
# unless the archive AND a rollback both fit; staging copies under /root
# (.openclaw-stage*) must be deleted BEFORE the window, they eat this headroom.
avail_gb=$(df --output=avail -BG / | tail -1 | tr -dc 0-9)
live_gb=$(du -sBG /root/.openclaw-main /root/.openclaw-edge | awk '{s+=$1} END {print s}')
need_gb=$(( live_gb / 2 + live_gb + 10 ))   # archive (~35% of live, rounded up) + rollback extract + margin
[ "$avail_gb" -ge "$need_gb" ] \
  || { echo "REFUSING: ${avail_gb}G free on /, need >= ${need_gb}G (live ${live_gb}G) for archive + rollback headroom"; exit 1; }
echo "disk gate OK: ${avail_gb}G free, need ${need_gb}G"
/opt/hydra/scripts/hydra-maintenance.sh start "openclaw 2026.8.2 upgrade" --ttl 3h
# DISABLE THE CI DEPLOY FOR THE WINDOW. deploy.yml runs on EVERY push to main
# and, on failure, runs scripts/rollback.sh (reverts /opt/hydra to
# .deployed-sha and RESTARTS the gateways). Merging #896/#899 would fire it;
# it would stop at Step 4d.6 (legacy stores still present until Phase 4) and
# then roll back + restart underneath the window. Disabled workflows do not
# queue runs, so re-enabling in Phase 5 does not replay them.
gh workflow disable "Deploy HYDRA" --repo Muso-AI/hydra \
  || { echo "REFUSING: could not disable the Deploy HYDRA workflow"; exit 1; }
# ASSERT the state with a structured, non-truncating query. Never pipe a
# command into a truncating reader here: under pipefail the writer gets
# SIGPIPE (rc 141) and this block aborts right after the disable, before
# anything is stopped or archived (observed in QA review).
wf_state=$(gh workflow list --all --repo Muso-AI/hydra --json name,state \
  --jq '.[] | select(.name=="Deploy HYDRA") | .state')
[ "$wf_state" = "disabled_manually" ] \
  || { echo "REFUSING: Deploy HYDRA workflow state is '${wf_state:-unknown}', expected disabled_manually"; exit 1; }
echo "Deploy HYDRA workflow: $wf_state"
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
  # (b) legacy exec approvals — LEAVE IN PLACE on 2026.8.2. On 8.1 this file
  # silently ABORTED the whole doctor pipeline before the auth stage (five
  # identical "failed" runs); 8.2 imports it into shared SQLite and removes it
  # after recording the migration (OBSERVED 2026-09-01), so archiving it here
  # would DISCARD approvals that the upgrade would otherwise preserve.
  # Report the shape VALUE-FREE only (the file carries a live socket.token —
  # never cat it into a recorded SSH/tmux session):
  if [ -f $d/exec-approvals.json ]; then
    echo "$d/exec-approvals.json present (defaults/agents: $(jq -r '[(.defaults|length),(.agents|length)] | join("/")' $d/exec-approvals.json)) — doctor will import it"
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

## Phase 3 — deploy runtime + config (PASS 1 of 2: stops at Step 4d.6 BY DESIGN)

Merge **#896 then #899** (workflow disabled in Phase 1, so nothing
auto-deploys). Then, from `/var/lib/hydra-release/repo` (never `/opt/hydra`):

```bash
bash -euo pipefail <<'RUNBOOK_BLOCK'
cd /var/lib/hydra-release/repo && git fetch origin && git reset --hard origin/main
grep -q 'OPENCLAW_VERSION:-2026.8.2' scripts/deploy.sh || { echo "REFUSING: main does not carry the 8.2 pin (#899 not merged?)"; exit 1; }
jq -e '.channels.slack.implicitMentions' openclaw-main.json >/dev/null || { echo "REFUSING: main does not carry the reshaped config (#896 not merged?)"; exit 1; }
# EXPECTED to stop at Step 4d.6 (see below) — but ONLY there. Capture the run
# and require the specific 4d.6 refusal marker; any other non-zero exit (e.g. a
# live-config lint failure at 4d.5, a plugin install failure) means the
# post-state below is NOT the one this runbook reasons about, and the one-way
# doctor migration must not start on top of it.
pass1_log=$(mktemp /root/deploy-pass1.XXXXXX.log)
pass1_rc=0
./scripts/deploy.sh --target all 2>&1 | tee "$pass1_log" || pass1_rc=${PIPESTATUS[0]}
if [ "$pass1_rc" -eq 0 ]; then
  echo "REFUSING: pass 1 exited 0 — it should have stopped at Step 4d.6; the legacy stores were not where this runbook expects them (did doctor already run?)"; exit 1
fi
grep -qF 'FATAL: un-archived pre-2026.8.1 legacy store(s) found' "$pass1_log" \
  || { echo "REFUSING: pass 1 failed (rc=$pass1_rc) somewhere OTHER than the Step 4d.6 legacy-store gate — read $pass1_log before doing anything else"; exit 1; }
echo "pass 1 stopped at the expected Step 4d.6 refusal (log: $pass1_log)"
# POST-STATE the pass MUST have reached before 4d.6 refused:
[ "$(openclaw --version | awk 'NR==1{print $2}')" = "2026.8.2" ] || { echo "REFUSING: runtime is not 2026.8.2 after pass 1"; exit 1; }
for p in main edge; do
  jq -e '.channels.slack.implicitMentions' /root/.openclaw-$p/openclaw.json >/dev/null || { echo "REFUSING: $p config not synced"; exit 1; }
  # (-print -quit, never a truncating pipe: a second match would SIGPIPE find under pipefail and abort the block)
  for plug in slack codex; do d=$(find /root/.openclaw-$p/npm/projects -maxdepth 4 -type d -path "*@openclaw/$plug" -print -quit); [ -n "$d" ] && [ "$(node -e "console.log(require('$d/package.json').version)")" = "2026.8.2" ] || { echo "REFUSING: $p plugin $plug not at 2026.8.2"; exit 1; }; done
done
for u in openclaw-gateway-main openclaw-gateway-edge; do
  st=$(systemctl is-active "$u" 2>/dev/null || true)   # is-active exits non-zero when inactive; capture the WORD, not the rc
  [ "$st" = "inactive" ] || [ "$st" = "failed" ] || { echo "REFUSING: $u reports '$st' — pass 1 must not have restarted anything, and Phase 4 needs both gateways stopped"; exit 1; }
done
echo "pass 1 post-state OK: runtime 2026.8.2, configs synced, plugins 2026.8.2, gateways stopped"
RUNBOOK_BLOCK
```

Pass 1 runs Steps 0 → 4d.5 (Node gate, `openclaw@2026.8.2`, rsync,
config sync, plugins `--force --pin --accept-capabilities`) and then
**FATALs at Step 4d.6** because the legacy `sessions.json` /
`auth-profiles.json` are still in place (doctor consumes them in Phase 4).
That FATAL is the "restarts held" mechanism: it posts an `:x: deploy FAILED`
line to Slack (expected inside the window; the watchdogs are muted) and
exits 1 WITHOUT rollback (deploy.sh has none; only CI's rollback.sh does,
and the workflow is disabled). Nothing is restarted and `.deployed-sha` is
not advanced. **Pass 2 runs after Phase 4** (see there).

## Phase 4 — doctor migration (gateways stopped; main first)

```bash
# Paste this WHOLE block: it runs as one fail-fast unit and ABORTS on the
# first failing command (set -euo pipefail) instead of scrolling past it.
bash -euo pipefail <<'RUNBOOK_BLOCK'
# MAIN:
export OPENCLAW_STATE_DIR=/root/.openclaw-main
openclaw --profile main doctor --fix                                   # auth + routes + agent DBs + sessions
# On 2026.8.2 the session import is already done by the line above; this is a
# VERIFYING no-op that prints the tally (expect "0 target(s), 0 legacy entries"):
openclaw --profile main doctor --fix --session-sqlite import --session-sqlite-all-agents
# VERIFY THE STORE, NOT THE REPORT. On an UNSCRUBBED run (Phase 2 skipped)
# doctor prints "Migrated 3 OpenAI Codex auth profile(s)" repeatedly and still
# writes NO authProfiles.store cell at all, while archiving the per-agent
# sources and burning one-shot receipts (OBSERVED 2026-09-01). The report is
# not evidence; this cell read is:
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
# CLEAR THE PER-AGENT FAN-OUT ROWS. Doctor does NOT touch them: every agent
# keeps the `primary` auth_profile_store row our 7.1 codex-auth-sync.sh wrote,
# holding 3 profiles keyed openai:chatgpt-<email> with the SYNC-MANAGED
# sentinel refresh (OBSERVED 2026-09-01 on 8.2: 11 agents on main, 1 on edge).
# That is 2.0's shape of the fan-out the single-refresher invariant forbids,
# and codex-auth-invariants.sh reports each one CRITICAL until cleared:
for db in /root/.openclaw-main/agents/*/agent/openclaw-agent.sqlite; do
  [ -f "$db" ] || continue
  node --experimental-sqlite --no-warnings -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync(process.argv[1]);
let cols; try { cols=db.prepare("pragma table_info(auth_profile_store)").all().map(c=>c.name); } catch (e) { process.exit(0); }
if (!cols.length) process.exit(0);
for (const r of db.prepare("select store_key, store_json from auth_profile_store").all()) {
  let j; try { j=JSON.parse(r.store_json); } catch (e) { continue; }
  if (!Object.keys(j.profiles||{}).length) continue;
  j.profiles={}; if (j.order) j.order={};
  db.prepare("update auth_profile_store set store_json=? where store_key=?").run(JSON.stringify(j), r.store_key);
  console.log("cleared fan-out row: "+process.argv[1]+" ["+r.store_key+"]");
}' "$db"
done
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
# GATE: main's auth invariants must read CLEAN before the gateway starts.
# REQUIRES PR #905 to be merged first. As shipped in #897 the checker queries a
# column that does not exist on 2.0 (`state_json`; the real one is
# `value_json`), so it exits UNEVALUATED on every call and this gate can never
# pass. Confirm before the window: the checker prints "clean", not "UNEVALUATED".
# SCOPE THIS TO MAIN. Edge has not been migrated yet at this point, and a 7.1
# state dir has NO config_machine_state table at all, so an unscoped run reports
# edge CRITICAL ("no authProfiles.store row — shared codex auth is MISSING")
# and would abort the upgrade between main's boot and edge's migration
# (verified 2026-09-01 against a real un-migrated edge state dir).
CODEX_AUTH_PROFILES=main /opt/hydra/scripts/lib/codex-auth-invariants.sh --check \
  || { echo "REFUSING to boot: main codex auth invariants not clean"; exit 1; }
# Do NOT start main by hand here: edge's doctor below must also run with BOTH
# gateways stopped, and the gateways are started by deploy PASS 2 (after edge),
# which also drops the retired refresh timer (5c), converges cron (6b), runs the
# smoke test (7) and finally advances .deployed-sha (8).
# verify battery: version pins; /proc state-dir pin; `skills list --agent clio`
# non-empty (NOTE: `skills list --all-agents` prints NOTHING on 2.0 — an empty
# read, not an empty catalog; always pass --agent); codex pong (clio);
# codex-auth-invariants.sh clean; watchdogs quiet.

# EDGE (auth starts empty by design):
export OPENCLAW_STATE_DIR=/root/.openclaw-edge
openclaw --profile edge doctor --fix
openclaw --profile edge doctor --fix --session-sqlite import --session-sqlite-all-agents
for db in /root/.openclaw-edge/agents/*/agent/openclaw-agent.sqlite; do
  [ -f "$db" ] || continue
  node --experimental-sqlite --no-warnings -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync(process.argv[1]);
let cols; try { cols=db.prepare("pragma table_info(auth_profile_store)").all().map(c=>c.name); } catch (e) { process.exit(0); }
if (!cols.length) process.exit(0);
for (const r of db.prepare("select store_key, store_json from auth_profile_store").all()) {
  let j; try { j=JSON.parse(r.store_json); } catch (e) { continue; }
  if (!Object.keys(j.profiles||{}).length) continue;
  j.profiles={}; if (j.order) j.order={};
  db.prepare("update auth_profile_store set store_json=? where store_key=?").run(JSON.stringify(j), r.store_key);
  console.log("cleared fan-out row: "+process.argv[1]+" ["+r.store_key+"]");
}' "$db"
done
# FULL GATE (both profiles) — edge now has its cell, holding 0 profiles until
# the Phase 5 device logins. CODEX_EXPECTED_PROFILES_EDGE=0 SKIPS the edge
# count check (it does not assert "zero"), so this same command stays correct
# after Phase 5 puts 3 profiles there.
/opt/hydra/scripts/lib/codex-auth-invariants.sh --check \
  || { echo "REFUSING to boot edge: codex auth invariants not clean"; exit 1; }
# EXACTLY-ZERO gate for edge (Option B: edge gets its OWN device logins in
# Phase 5). The checker above validates SHAPE; CODEX_EXPECTED_PROFILES_EDGE=0
# means "skip the count", not "assert zero" — so a structurally valid profile
# that doctor imported from a missed source would pass it. Read the cell.
node --experimental-sqlite --no-warnings -e '
const {DatabaseSync}=require("node:sqlite");
const db=new DatabaseSync("/root/.openclaw-edge/state/openclaw.sqlite",{readOnly:true});
const r=db.prepare("select value_json from config_machine_state where state_key=?").get("authProfiles.store");
const n=r ? Object.keys(JSON.parse(r.value_json).profiles||{}).length : 0;
if (n!==0) { console.error("REFUSING: edge authProfiles.store holds "+n+" profile(s) before the Phase 5 device logins — a missed pre-doctor scrub imported credentials; archive them and re-check"); process.exit(1); }
console.log("edge cell: 0 profiles (as designed before Phase 5)");'
RUNBOOK_BLOCK
```

### Phase 4b — deploy PASS 2 (starts the fleet)

```bash
bash -euo pipefail <<'RUNBOOK_BLOCK'
cd /var/lib/hydra-release/repo
# Pass 1 left /opt/hydra at the new tree while .deployed-sha still names the
# old one, so Step 0/4a would call that "content drift" and BLOCK. That drift
# IS the pass-1 rsync — nothing else wrote to /opt/hydra (gateways stopped,
# watchdogs muted). HYDRA_FORCE=1 skips exactly those two checks and nothing
# else; 4d.6 now passes because doctor archived the legacy stores as
# *.migrated-*.
for p in main edge; do
  n=$(find /root/.openclaw-$p/agents -maxdepth 3 \( -name sessions.json -o -name auth-profiles.json \) -type f | wc -l)
  [ "$n" -eq 0 ] || { echo "REFUSING pass 2: $n un-archived legacy store(s) under $p — Phase 4 incomplete"; exit 1; }
done
HYDRA_FORCE=1 ./scripts/deploy.sh --target all
# Step 6 finds both gateways STOPPED: the drain path cannot run and falls
# back (loudly, one Slack line) to systemctl restart — that is the intended
# start. Step 7 pings edge support BEFORE the Phase 5 logins: it answers on
# the OpenRouter fallback (fallback-swallow watchdog is muted), which is fine.
[ "$(tr -d '[:space:]' < /opt/hydra/.deployed-sha)" = "$(git rev-parse HEAD)" ] \
  || { echo "REFUSING: .deployed-sha did not advance to HEAD — pass 2 did not complete"; exit 1; }
# Same pipefail trap as the Phase 3 is-active check: `is-enabled` exits non-zero
# for "disabled", so a piped grep would REFUSE on the correct state. Capture the word.
timer_state=$(systemctl is-enabled codex-token-refresh.timer 2>/dev/null || true)
case "$timer_state" in
  disabled|masked|"") echo "codex-token-refresh.timer: ${timer_state:-absent} (retired)";;
  *) echo "REFUSING: codex-token-refresh.timer is '$timer_state' after pass 2 (5c should have retired it on a 2.0 runtime)"; exit 1;;
esac
RUNBOOK_BLOCK
```

Doctor's one-shot receipts mean a botched import cannot simply be re-run:
restore the archived `*.migrated-*` source, clear the matching
`migration_sources`/`migration_runs` rows (staging-rehearsed), and re-run
with gateways stopped.

## Phase 5 — edge device logins (Option B) + close

Re-enable the CI deploy AFTER the fleet is verified:
`gh workflow enable "Deploy HYDRA" --repo Muso-AI/hydra` (nothing replays;
the next merge to main deploys normally and must pass the 4d.6 gate cleanly).

**Mechanism VERIFIED 2026-09-07 on 2026.8.2** (openai plugin disabled, codex
2026.8.2 installed): `openclaw --profile edge models auth login --provider
openai --device-code` prints an "OpenAI Codex device code" box (URL + code,
15-minute expiry) and polls for authorization — the codex plugin owns this
flow on 2.0, so the 7.1-era "No provider plugins found" failure is gone. It
REQUIRES an interactive TTY (`ssh -t`, not a piped command); in a non-TTY it
exits 1 with "requires an interactive TTY". Run it 3 × (one per account;
Aaron opens the URL in HIS browser, signed into that account, and enters the
code), then `openclaw --profile edge models auth list` must show 3
`openai:*` profiles and `codex-auth-invariants.sh --check` must be clean
with `CODEX_EXPECTED_PROFILES_EDGE=3`. Caroline answers in Intercom;
`hydra-maintenance.sh stop`. Keep the archive ≥ 7
days; 48h quiet watchdogs before trusting steady state.

## Rollback

```bash
# Paste this WHOLE block: it runs as one fail-fast unit and ABORTS on the
# first failing command (set -euo pipefail) instead of scrolling past it.
# ORDER MATTERS: state is restored BEFORE the runtime is downgraded and BEFORE
# anything restarts. The downgrade helper is invoked non-interactively
# (--yes: its confirmation `read` would otherwise consume the next line of this
# here-doc and abort) and with --no-restart, so it only swaps the binary and
# plugins; this block owns the restore and the restart. Its own --state-archive
# path is deliberately NOT used here — this block's verify-then-extract is the
# stronger restore.
bash -euo pipefail <<'RUNBOOK_BLOCK'
# The block runs in a FRESH shell (quoted here-doc, -u): every variable it uses
# must be assigned INSIDE it. Fill in <ts> from Phase 1 on this line before pasting.
ARCHIVE=/root/openclaw-state-pre81-<ts>.tar.gz
[ -f "$ARCHIVE" ] && [ -f "$ARCHIVE.sha256" ] || { echo "REFUSING: archive or its .sha256 not found at $ARCHIVE (fill in <ts>)"; exit 1; }
systemctl stop openclaw-gateway-main openclaw-gateway-edge
while pgrep -f "[o]penclaw/dist/index.js" >/dev/null; do sleep 2; done
# 1. PROVE the archive is complete, checksum-intact, and actually EXTRACTS
# (into a temp dir) BEFORE deleting anything — a partial tar still ls-es
# fine, and a wrong <ts> discovered after rm -rf leaves nothing to restore:
# `sha256sum -c` resolves the name inside the .sha256 file relative to the CWD;
# run it from the archive's directory so both absolute and bare names verify.
( cd "$(dirname "$ARCHIVE")" && sha256sum -c "$(basename "$ARCHIVE").sha256" ) \
  || { echo "REFUSING: archive checksum mismatch"; exit 1; }
tmp=$(mktemp -d /root/pre81-restore.XXXXXX)
tar -C "$tmp" -xzf "$ARCHIVE" \
  || { echo "REFUSING: archive does not extract"; rm -rf "$tmp"; exit 1; }
for d in .openclaw-main .openclaw-edge; do
  [ -s "$tmp/$d/openclaw.json" ] && { [ -e "$tmp/$d/state/openclaw.sqlite" ] || [ -e "$tmp/$d/agents" ]; } \
    || { echo "REFUSING: extracted $d is missing critical trees"; rm -rf "$tmp"; exit 1; }
done
# 2. Swap the state dirs (7.1-shape state back in place).
rm -rf /root/.openclaw-main /root/.openclaw-edge
mv "$tmp/.openclaw-main" /root/.openclaw-main && mv "$tmp/.openclaw-edge" /root/.openclaw-edge
rmdir "$tmp"
# 3. Downgrade the runtime + lockstep plugins, WITHOUT restarting (the state
# is already 7.1-shape, so this is the only order in which a restart can work).
/opt/hydra/scripts/downgrade-openclaw-runtime.sh --yes --no-restart \
  || { echo "REFUSING: runtime downgrade failed — gateways are STOPPED on restored 7.1 state; fix the install before starting anything"; exit 1; }
[ "$(openclaw --version | awk 'NR==1{print $2}')" = "2026.7.1" ] || { echo "REFUSING: binary is not 2026.7.1 after downgrade"; exit 1; }
# 4. The 7.1 core needs the out-of-band refresher again.
systemctl enable --now codex-token-refresh.timer
# 5. Start, and verify readiness by the health endpoint (is-active precedes listening).
systemctl start openclaw-gateway-main openclaw-gateway-edge
for p in main edge; do
  for i in $(seq 1 60); do openclaw --profile "$p" health --json >/dev/null 2>&1 && break; sleep 3; done
  openclaw --profile "$p" health --json >/dev/null 2>&1 || { echo "REFUSING: $p gateway did not become healthy on 2026.7.1 — inspect journalctl -u openclaw-gateway-$p"; exit 1; }
done
echo "rollback complete: 2026.7.1 running on the pre-8.1 archive"
RUNBOOK_BLOCK
```

**Rehearsed 2026-09-04** on a fresh neutered copy of prod `-main` (50G): archive
17G in 15m36s, `sha256sum -c` OK, extract-to-tmp + swap 4m08s, and the restored
tree BOOTS on the prod 2026.7.1 binary with its 13 legacy `sessions.json` intact.
Only the runtime downgrade (`npm install -g`) was not exercised, since it
touches the live global install. The three boot failures hit during the
rehearsal were all staging-neuter artifacts (env-provider `path`, secrets file
mode 0644, missing SecretRef pointers), none of which exist on prod.

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
  `auth-profiles.json` (PR2 rewrites all consumers); every per-agent
  `auth_profile_store` row is EMPTY (read-through only) — all three are what
  `codex-auth-invariants.sh --check` asserts, and it must exit 0.
- `OPENCLAW_STATE_DIR` pins unchanged + asserted via `/proc` (unless the
  pin-required test proves it obsolete — then removed deliberately).
- Session budgets unchanged (10000 / 8gb / 6gb); budget guard reads
  SQLite; `cron.sessionRetention` native at default 24h.
