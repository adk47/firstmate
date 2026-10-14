# Runbook: node-8 system Node.js 22.23.1 → 24.x (NodeSource apt)

Manual pre-step for MUS-5087 (parent MUS-5057). Same shape as
`UPGRADE-2026.7.1.md`: nothing here is run by `deploy.sh`. Every command in
§1–§8 is **"to run in the window"** and was NOT executed when this was written
(no node-8 access) — none of it is evidence of anything. Repo facts below were
read at `origin/main` `70deafc4`.

## §0 Facts, target, approvals

| | |
|---|---|
| Change | node-8 **system** Node 22.23.1 → 24.x via NodeSource `node_24.x`. Paperclip then uses the system runtime; there is no second Node on the box. |
| Target | **`24.21.0-1nodesource1`** (newest in the `node_24.x` repo on 9 Oct). Any version `>= 24.16.0 < 25` is acceptable; the Step 2 assert enforces the band. |
| Why `>= 24.16.0` | openclaw **2026.9.8** (W1 step 3) `engines.node` = `>=24.16.0 <25 \|\| >=26.1.0`. 24.15.x boots 8.35 and then blocks step 3. |
| Why `< 25` | Neither engines range accepts 25.0–25.8; 8.35 accepts `>=25.9.0` but 9.8 does not. Stay on 24. |
| openclaw **2026.8.35** (pinned `scripts/deploy.sh:26`) | `engines.node` = `>=22.22.3 <23 \|\| >=24.15.0 <25 \|\| >=25.9.0` — accepts 22 **and** 24, so the bump is safe for the current pin. |
| Re-check | `curl -s https://registry.npmjs.org/openclaw/<version> \| jq .engines` |
| Approved | Aaron, 9 Oct (apt change). |
| Window | Nick picks it. |
| Runs it | CoS, line by line. |

Rollback is the pin **and** the old NodeSource repo, both recorded in §1, not a
number in this file. `setup_24.x` (§2) deletes the old major's apt source, so §8
re-adds it before it downgrades.

## §1 Pre-flight capture (also the rollback inventory)

```bash
CAP=/root/node24-preflight-$(date -u +%Y%m%dT%H%M%SZ).txt
{
  echo "## node --version";                  node --version
  echo "## npm --version";                   npm --version
  echo "## npm ls -g --depth=0";             npm ls -g --depth=0
  echo "## dpkg -l nodejs";                  dpkg -l nodejs
  echo "## apt-cache policy nodejs";          apt-cache policy nodejs
  echo "## apt holds";                       apt-mark showhold
  echo "## nodesource apt source (old repo, §8 re-adds it)"; head -50 /etc/apt/sources.list.d/nodesource.* 2>&1
  echo "## running services";                systemctl list-units --type=service --state=running --no-pager
  echo "## /etc/cron.d";                     ls -1 /etc/cron.d
  echo "## timers";                          systemctl list-timers --all --no-pager
  echo "## procs on a node binary";          ls -l /proc/[0-9]*/exe 2>/dev/null | grep -E '/node( |$)'
  echo "## units whose ExecStart names node"; grep -lE 'ExecStart=.*\bnode\b' /etc/systemd/system/*.service
  echo "## build toolchain (tree-sitter-bash source fallback, §4)"; command -v g++ make python3
} > "$CAP" 2>&1
echo "$CAP"
```

**The `dpkg -l nodejs` version in `$CAP` is the rollback pin** (format
`22.x.y-1nodesource1`). Read it back now and keep it:
`ROLLBACK_PIN=$(dpkg-query -W -f='${Version}' nodejs); echo "$ROLLBACK_PIN"`.
If `apt holds` lists `nodejs`, run `apt-mark unhold nodejs` before §2.

**Host-enumeration step (catches host-only units).** Diff the capture against
§5/§6: any running service or `/etc/cron.d` file that is not named there is
host-only and unreviewed — list it on the card before you continue. Known
host-only facts at `origin/main`: `muso-mcp-gate` exists nowhere in the repo;
`intercom-webhook` has no unit in the repo (only `scripts/intercom-webhook.js`
and the monitor label at `k8s/prod/monitoring/webhook-health-monitor.yaml:45`).
Both may run as node on the host. Find them with the "units whose ExecStart
names node" and "procs on a node binary" lines above and add them to the §5
restart list with the same verify (service `active`, no `ERR_DLOPEN_FAILED` in
`journalctl -u <unit> --since -5m`).

## §2 The apt change

```bash
/opt/hydra/scripts/hydra-maintenance.sh start "node 22->24" --ttl 2h   # watchdogs stand down
systemctl stop codex-token-refresh.timer codex-canonical-refresh.timer # both restart gateways
NODE24_PIN=24.21.0-1nodesource1
curl -fsSL https://deb.nodesource.com/setup_24.x | bash - \
  && { apt-cache madison nodejs | grep -F "$NODE24_PIN" || { echo "pin $NODE24_PIN not in node_24.x: STOP, go to §8"; false; }; } \
  && apt-get install -y --allow-downgrades "nodejs=$NODE24_PIN" \
  && apt-mark hold nodejs \
  || echo "APT STEP FAILED: go to §8"
node --version && npm --version && node -p process.versions.modules
node -e 'const[a,b]=process.versions.node.split(".").map(Number);process.exit(a===24&&b>=16?0:1)' && echo "band OK" || echo "BAND FAIL: go to §8"
```

Expected: `v24.21.0`, `band OK`, ABI `137`. Anything else → §8.

## §3 Re-assert the global openclaw install BEFORE any restart

The gateway units exec `/usr/bin/node /usr/lib/node_modules/openclaw/dist/index.js`
(`scripts/migrate-to-multi-gateway.sh:19`, unit heredocs `:96` main, `:124`
edge). An apt nodejs swap can leave `/usr/lib/node_modules` stale or empty. Do
not rely on the 06:15 Deploy HYDRA to heal it.

```bash
ls -l /usr/lib/node_modules/openclaw/dist/index.js
PINNED=$(grep -m1 '^OPENCLAW_VERSION=' /opt/hydra/scripts/deploy.sh | sed -E 's/.*:-([^}]+)\}.*/\1/'); echo "$PINNED"   # 2026.8.35
npm install -g "openclaw@$PINNED"   # unconditional: a matching version string does not prove the addons were built for Node 24
openclaw --version | grep -F "$PINNED"
```

Expected: file exists; `openclaw --version` prints `$PINNED`. `npm install -g`
rebuilds the native addons for the new Node — see the `tree-sitter-bash` note
in §4. Do this with the gateways still on the old process.

## §4 Native addon load checks (to run in the window — never evidence)

Run from the global package so resolution matches the gateway:
`cd /usr/lib/node_modules/openclaw`. Failure signature for every row:
`ERR_DLOPEN_FAILED` or `NODE_MODULE_VERSION <n>. This version of Node.js requires NODE_MODULE_VERSION 137` → **§8 rollback**.

| artifact | provenance | check (paste as one line) | expected |
|---|---|---|---|
| `@lydell/node-pty@1.2.0-beta.15` → `@lydell/node-pty-linux-x64` | openclaw 2026.8.35 `dependencies` | `node --input-type=module -e "await import('@lydell/node-pty'); console.log('node-pty ok')"` | `node-pty ok` |
| `tree-sitter-bash@0.25.1` (`install: node-gyp-build`, `node-addon-api@^8.2.1`) | openclaw 2026.8.35 `dependencies` | `node --input-type=module -e "await import('tree-sitter-bash'); console.log('tree-sitter-bash ok')"` | `tree-sitter-bash ok` |
| `sqlite-vec@0.1.9` → `sqlite-vec-linux-x64` | openclaw 2026.8.35 **`optionalDependencies`** | `node --input-type=module -e "const m=await import('sqlite-vec'); console.log(m.getLoadablePath())"` | a `.so` path under `sqlite-vec-linux-x64`. **Absent is legal** (`ERR_MODULE_NOT_FOUND` for the top-level `sqlite-vec` is not a failure; a missing `sqlite-vec-linux-x64` is). It is a SQLite extension, not a Node addon, so it is not ABI-bound; only a `DLOPEN` error counts. |
| `@ubjs/node@0.31.0-3` → `@ubjs/node-linux-x64-gnu` | `plugins/intercom/pnpm-lock.yaml:688-731, 2615-2623` | `cd /opt/hydra/plugins/intercom && node --input-type=module -e "await import('@ubjs/node'); console.log('ubjs ok')"` | `ubjs ok` |

**`tree-sitter-bash` is the one most likely to break the install, not just the
load.** `node-gyp-build` uses a prebuild if one matches the platform/ABI and
otherwise falls back to a source build, which needs `g++`, `make`, `python3`
(captured in §1) and downloads Node 24 headers from nodejs.org. If `npm install
-g` in §3 fails inside `tree-sitter-bash`'s install script, or the check above
prints a DLOPEN error: do not hand-patch — go to §8.

**Plugin install.** `scripts/deploy.sh:605` runs `pnpm install --frozen-lockfile`
in `plugins/<name>`, then `:642` does a module-load self-check of
`dist/index.js`. The Node bump can break the intercom plugin install (the
`@ubjs/node-linux-x64-gnu` optional binary), not only its load. Confirm now,
before the next scheduled Deploy HYDRA does it for you:

```bash
cd /opt/hydra/plugins/intercom && pnpm install --frozen-lockfile && node --input-type=module -e "import('./dist/index.js').then(()=>console.log('intercom plugin ok')).catch(e=>{console.error(e);process.exit(1)})"
```

Also prove the `node:sqlite` users (see §5) accept their flag on 24:
`node --experimental-sqlite --no-warnings -e 'const {DatabaseSync}=require("node:sqlite"); new DatabaseSync(":memory:"); console.log("sqlite ok")'` → `sqlite ok`.

## §5 Restart list, in order, with a per-unit verify

The dependency is **transitive**. No timer unit execs `/usr/bin/node`: they
exec `python3`/bash, which shell out to `openclaw` (a Node app on the system
node), `node` directly (`node:sqlite`), `muso`, or `codex`. Counts at this
base: `scripts/install-aux-units.sh` has **36 service / 33 timer** heredocs
(the card's 34/32 is the earlier count; `hydra-unit-failed@` `:2510` and
`codex-edge-mirror` `:2522` sit under a conditional). Each row below was
confirmed by reading the script; the card's line-level sweep had docstring and
string false positives, listed after the table.

**`muso` is a Go binary** (`muso-cli` repo: `go.mod`, `cmd/`, `install.sh`
downloads a release archive), so units that only call `muso` do not touch system
Node. Host fact to confirm: `file "$(command -v muso)"` says `ELF`. It also means
`slack-notify.sh:90` (`muso slack send`) adds no Node dependency.

**1. Long-lived processes — restart, in this order** (maintenance window open):

| unit | where it runs node | restart | verify |
|---|---|---|---|
| `openclaw-gateway-main` | `migrate-to-multi-gateway.sh:96` | `systemctl restart openclaw-gateway-main` | `systemctl is-active` = `active`; `openclaw --profile main gateway call health` ok; `journalctl -u openclaw-gateway-main --since -2m \| grep -cE 'ERR_DLOPEN\|NODE_MODULE_VERSION'` = `0` |
| `openclaw-gateway-edge` | `migrate-to-multi-gateway.sh:124` | `systemctl restart openclaw-gateway-edge` | same with `--profile edge` and `-u openclaw-gateway-edge` |
| host-only node units from §1 (`intercom-webhook`, `muso-mcp-gate` if present) | not in repo | `systemctl restart <unit>` | `active`, no DLOPEN in journal |
| `hydra-main-prune-restart.timer` → `.service` (`install-aux-units.sh:2548-2585` at `origin/main`, not the base above) | `scripts/main-prune-restart.sh:8-9` → `openclaw sessions cleanup --enforce` (offline) → start main | **No manual restart.** The timer stops and starts `openclaw-gateway-main` itself, nightly **02:30 UTC**. Verify on the first run: `systemctl show hydra-main-prune-restart.service -p Result -p ExecMainStatus` → `Result=success` `ExecMainStatus=0`; `systemctl is-active openclaw-gateway-main` = `active`; `openclaw --profile main gateway call health` ok. |

**`hydra-main-prune-restart` notes (all citations at `origin/main`, not the base above).**

- **It replaces the hand-placed main bridge; expect exactly one 02:30 UTC main restart.** The bridge (`/usr/local/sbin/hydra-main-{prune-restart,nightly-reset}.sh`, via the transient `hydra-main-nightly-reset.timer`) also fired at 02:30 UTC. `install-aux-units.sh:2517-2546` retires it before the managed timer is armed: it stops the bridge timer, waits up to `AUX_BRIDGE_WAIT_SECS` (900 s) for a legacy run to finish, and deletes the hand-placed scripts. If a legacy run is still going after 900 s, the install fails with nothing removed and nothing armed, and the next deploy retries. **Passing looks like:** `systemctl list-timers --all` shows one 02:30 UTC main timer (`hydra-main-prune-restart.timer`), `hydra-main-nightly-reset.timer` is not active (stopped or absent), and `/usr/local/sbin/hydra-main-*.sh` are gone. Two armed at 02:30 is an anomaly: stop and escalate. One is correct.
- **Shared lock, by design.** The prune, `deploy.sh` and `rollback.sh` share `/run/lock/hydra-main-prune-restart.lock` (`scripts/lib/main-prune-lock.sh`, commit `61f60bdfe`). The prune takes it without waiting, so it skips while a deploy holds it. Its 02:30 start is 90 min before the 04:00 UTC deploy (`.github/workflows/deploy.yml:11`). Do not "fix" that apparent collision; the lock serialises the two on purpose.
- **First execution is the night after install.** If the 14 Oct 04:00 UTC deploy installs it, the first timer run is **15 Oct 02:30 UTC**, on whichever Node runtime is live then (22 or 24, depending on whether §2 has run). A run skips if main restarted less than 4 h earlier (`HYDRA_MAIN_MIN_UPTIME_H=4`, same unit block), so a manual restart shortly before 02:30 makes that night's run a no-op.

**2. Timer units that reach node.** Cron/timers re-exec per tick, so these need
**no restart**. Do **not** `systemctl start` them to test: they post to Intercom,
close conversations and add/remove openclaw crons. Verify on the next tick:
`systemctl show <unit>.service -p Result -p ExecMainStatus` → `Result=success`
`ExecMainStatus=0`, and no DLOPEN line in `journalctl -u <unit>.service -n 50`.

| unit (`install-aux-units.sh:` heredoc line) | node reached at |
|---|---|
| `hydra-peer-labels` `:403` | `provision-peer-labels.sh:104,127` (`"$OPENCLAW_BIN" … gateway call`) |
| `hydra-session-thread-retention@` `:441` | `prune-completed-slack-thread-sessions.sh:80` |
| `openclaw-edge-reindex` `:1538` | `openclaw-edge-reindex-on-start.sh:76,91` |
| `cto-nightly-driver` `:1421` | `cto-nightly-driver.sh:149,171,419` (`"$OPENCLAW" … cron`); gateway pre-start heal `openclaw-pre-start-heal.sh:183` |
| `qa-review-reconcile` `:2681` | `qa-review-reconcile.sh:476` (`"$OPENCLAW" … cron list`) |
| `cs-selfserve-backlog-collect` `:799`, `cs-selfserve-backlog` `:825` | `cs-selfserve-backlog.py:802` (`openclaw --version`) |
| `codex-token-refresh` `:2385` | `lib/codex-oauth-refresh.sh` → `lib/codex-mint-idtoken.sh:62,124` (`node:sqlite`); restarts gateways via `lib/gateway-restart.sh:257` |
| `codex-canonical-refresh` `:2444` | `lib/codex-mint-idtoken.sh` via `MINT_BIN` `codex-canonical-refresh.sh:34`; `lib/gateway-restart.sh` `:142` |
| `codex-edge-mirror` `:2522` | `lib/codex-edge-mirror.sh:126,645` (`node --experimental-sqlite -e`) |

**3. Timer units read and found NOT to reach node.**

| unit (`:line`) | why |
|---|---|
| `intercom-intake-watchdog` `:491` | `intercom-intake-watchdog.py:228` runs `bash hydra-maintenance.sh`; `:36` is a docstring |
| `close-resolved-conversations` `:547`, `overdue-verification-notifier` `:598`, `resolve-notify` `:649`, `close-duplicate-conversations` `:955`, `cs-needs-human-digest` `:754`, `cs-needs-human-digest-delta` `:864` | `urllib` + `lib/jev_shadow.py` → `lib/jev.sh`; no node/openclaw call (the sweep hits were docstrings) |
| `resolution-matcher` `:708` | `resolution-matcher.py:292` `muso query` (Go) |
| `cs-sla-report` `:905` | `cs-sla-report.py:456` `muso api GET` (Go) |
| `caroline-behavior-digest` `:1053` | `caroline-behavior-digest.py:493` runs `muso-read.sh` — **host-only wrapper, not in the repo**; confirm in the window that it execs the Go `muso` (`head -5 "$(command -v muso-read.sh)"`) |
| `clickup-todo-dedupe` `:1005` | python batch helper under `workspaces/operations/skills/muso-clickup-ticket-sweeper/scripts/clickup_batch_update.py`; no node |
| `clickup-sla-digest` `:1318`, `close-merged-tickets` `:1374` | `lib/clickup-muso.sh:55`, `close-merged-tickets.sh:123` (`muso`, Go) |
| `support-changelog-sync` `:1126`, `sync-platform-llms` `:1193`, `sync-app-pricing` `:1267` | curl/gh/jq + `lib/slack-notify.sh:90` (`muso`, Go); the `openclaw` hits are prose |
| `hydra-release` `:2005`, `hydra-release-watch` `:2098` | `release-cron.sh:116` → `release.sh`; git/gh only |
| `hydra-daily-audit` `:2172` | `hydra-daily-audit.py:172,249` `journalctl` only |
| `hydra-weekly-cleanup` `:2228` | `weekly-cleanup.sh:116` is an rsync-style exclude string, not a call |
| `openclaw-config-write-audit@` `:1559` | `openclaw-config-write-audit.sh:75` `pgrep` only |
| **read, no hit:** `hydra-jev-shadow-prune` `:2281`, `hydra-tmp-reaper` `:2329`, `hydra-company-finder-cache-refresh` `:2572` (uses `muso nocodb`, Go), `qa-approval-retry` `:2796` (`qa-slack-dm.sh:55` `muso`, Go), `intercom-rights-holder-watchdog` `:548-579` (`origin/main` line; `.service` + `.timer`, every 10 min, `ExecStart=/usr/bin/python3`; `openclaw` appears only in a docstring) | no node, no openclaw call (python3 only) |

## §6 The 15 `/etc/cron.d/` jobs (not in the parent card's list)

`install-aux-units.sh:1604, 1635, 1664, 1692, 1713, 1726, 1741, 1758, 1809,
1836, 1848, 1877, 1893, 1915` (pinned at `70deafc4`), plus
`agent-soul-delivery-guard` at `:1861` (added by #1152 after that base; line is
at `origin/main` `0a96b156`). They need **no restart** (cron re-execs per
tick). Node-dependent ones (read in the scripts):

| job (`:line`, schedule) | node reached at |
|---|---|
| `openclaw-watchdog` `:1604` `*/2` | `openclaw-watchdog.sh:324` (`openclaw config validate`), `lib/gateway-restart.sh` |
| `codex-keepalive` `:1635` `*/15` | `codex-keepalive.sh:177` (`node --experimental-sqlite`) |
| `cron-health-watchdog` `:1692` `*/5` | `lib/ensure-session-budget-headroom.sh:296` (`openclaw sessions`) |
| `stuck-lane-watchdog` `:1741` `*/2` | `stuck-lane-watchdog.sh:386` (`openclaw gateway call`) |
| `sentry-issue-watchdog` `:1836` `*/30` | `sentry-issue-watchdog.sh:1658` (`openclaw` dispatch) |
| `caroline-rag-index-watchdog` `:1915` `*/10` | `caroline-rag-index-watchdog.sh:215,433` (`openclaw memory`) |
| `codex-quota-refresh` `:1664` `*/20` | `lib/codex-quota-probe.sh:69` → `lib/codex-auth-store.sh:51` (`node:sqlite`) |

Not node (read): `refund-credit-overlap-watchdog` `:1713`, `fallback-swallow-watchdog` `:1726`,
`merge-landing-watchdog` `:1758`, `prod-log-alert-watchdog` `:1809`,
`stale-ticket-watchdog` `:1848`, `mercury-token-watchdog` `:1877`,
`ads-inquiry-watchdog` `:1893`, `agent-soul-delivery-guard` `:1861`
(`check-agent-soul-delivery.sh` is bash; `openclaw`/`node` appear only in path
strings and comments). None invoke `openclaw` or `node`.

**First-tick check** (minimum: `openclaw-watchdog`, `codex-keepalive`,
`cron-health-watchdog`; add the rest of the node rows):
`tail -n 30 /var/log/openclaw-watchdog.log /var/log/codex-keepalive.log /var/log/cron-health-watchdog.log`
after the next tick — expect fresh timestamps and no `ERR_DLOPEN`,
`NODE_MODULE_VERSION`, or `node: bad option` lines. Also run the read-only
auth guard: `/opt/hydra/scripts/lib/codex-auth-sync.sh --check` → `clean`.

**Self-hosted CI check (after the restarts, before closing the window).** The hydra runners use the system Node, so confirm CI still works on Node 24: `node --version` shows `v24.x` (>= 24.16, < 25) and `pnpm --version` succeeds on the runner host. Then re-run the `plugin-tests` job (`pr-validate.yml:1609`) by re-running it on the latest `PR Validation` run (`gh run rerun <run-id> --job <job-id>` as `adk47`). Expected: green. A red `pnpm install`/`build`/`test` step for a plugin under Node 24 ⇒ record it on the card; it breaks validation of every PR, so treat it as a §8 rollback trigger unless the CTO says otherwise.

Close the window: `systemctl start codex-canonical-refresh.timer; /opt/hydra/scripts/hydra-maintenance.sh stop`. Do **not** start `codex-token-refresh.timer`: `install-aux-units.sh:2438-2439` retires it on openclaw >= 2026.8 (it refreshes the archived pre-8.1 JSON store), so it is meant to stay off.

## §7 NOT affected — do not check

- **The 4 GitHub runners' Actions runtime only:** the runner executes Actions
  internals on its own bundled node20 (host fact — confirm in the window with
  `ls /*/externals/ 2>/dev/null`). **Their CI jobs are NOT unaffected:** the
  `plugin-tests` job (`pr-validate.yml:1609`, `runs-on: [self-hosted, hydra]`)
  calls the **system** `node`/`npm` (`:1640-1656`) and runs `pnpm install
  --frozen-lockfile`, `pnpm run build` and `pnpm test` for every `plugins/*`
  (`:1765-1795`). After the swap this is verified in the window — see the
  "Self-hosted CI check" paragraph in §6, before `Close the window`.
- **k8s pods:** own images (`k8s/prod/**`); no host Node.
- **`@openclaw/fs-safe@0.5.6`:** pure JS — `engines {"node":">=22"}`, no
  gypfile, no native optional deps; its `native:*` scripts are dev-only. There is
  no `fs-safe-native` package (npm 404).
- **`web-tree-sitter@0.26.13`:** WASM, not ABI-bound.

## §8 Rollback (one block)

```bash
systemctl stop codex-token-refresh.timer codex-canonical-refresh.timer
ROLLBACK_PIN=$(awk '/^[hi]i +nodejs /{print $3}' "$CAP"); echo "rolling back to $ROLLBACK_PIN"
OLD_MAJOR=${ROLLBACK_PIN%%.*}
test -n "$ROLLBACK_PIN" \
  && apt-mark unhold nodejs \
  && curl -fsSL "https://deb.nodesource.com/setup_${OLD_MAJOR}.x" | bash - \
  && { apt-cache madison nodejs | grep -F "$ROLLBACK_PIN" || { echo "ROLLBACK ABORTED: $ROLLBACK_PIN not in node_${OLD_MAJOR}.x"; false; }; } \
  && apt-get install -y --allow-downgrades "nodejs=$ROLLBACK_PIN" \
  && apt-mark hold nodejs \
  && [ "$(dpkg-query -W -f='${Version}' nodejs)" = "$ROLLBACK_PIN" ] \
  && node --version \
  && PINNED=$(grep -m1 '^OPENCLAW_VERSION=' /opt/hydra/scripts/deploy.sh | sed -E 's/.*:-([^}]+)\}.*/\1/') \
  && npm install -g "openclaw@$PINNED" \
  && openclaw --version \
  && systemctl restart openclaw-gateway-main \
  && systemctl restart openclaw-gateway-edge \
  && systemctl is-active openclaw-gateway-main openclaw-gateway-edge \
  && (cd /usr/lib/node_modules/openclaw \
    && node --input-type=module -e "await import('@lydell/node-pty'); console.log('node-pty ok')" \
    && node --input-type=module -e "await import('tree-sitter-bash'); console.log('tree-sitter-bash ok')" \
    && node --input-type=module -e 'try { const m = await import("sqlite-vec"); console.log(m.getLoadablePath()) } catch (e) { if (e.code === "ERR_MODULE_NOT_FOUND" && /Cannot find package .sqlite-vec. /.test(e.message)) console.log("sqlite-vec absent: legal (optionalDependency)"); else throw e }') \
  && (cd /opt/hydra/plugins/intercom && pnpm install --frozen-lockfile \
    && node --input-type=module -e "await import('@ubjs/node'); console.log('ubjs ok')") \
  && systemctl start codex-canonical-refresh.timer \
  && /opt/hydra/scripts/hydra-maintenance.sh stop \
  && echo "ROLLBACK OK" || echo "ROLLBACK FAILED at the step above: STOP, escalate"
```

Restart the §5.1 host-only units too if §1 found any. `$CAP` is the §1
file; if the shell was lost, set it with `CAP=$(ls -t /root/node24-preflight-*.txt | head -1)`.
`sqlite-vec` absent (`ERR_MODULE_NOT_FOUND` for the top-level `sqlite-vec` package only; a missing `sqlite-vec-linux-x64` is a failure) is legal (see §4) and the block tolerates only that; any other error, such as `ERR_DLOPEN_FAILED`, fails the block.

## §9 The backstop (as it exists at `origin/main` `70deafc4`)

`scripts/deploy.sh:431-445` (`install_openclaw`) fails the deploy loud **before**
`npm install -g`: `node --version` missing → `:438` error; Node below
`OPENCLAW_NODE_FLOOR` (`:33`, default `22.22.3`) → `:441-444` error pointing at
`UPGRADE-2026.7.1.md`. It is a **floor only**: it has no upper bound and no
24.16 floor, so it would accept Node 24.15.x or 25.x that the next openclaw
rejects. The band widening is MUS-5087's second card and is not described here
as existing behaviour. Until it merges, §2's assert is the only guard on the
`>= 24.16.0 < 25` band.
