# Deploy / CI / PR field guide (the gotchas behind the procedure)

This is the field guide to *why* hydra deploys, CI checks, and PRs go red, and
what is a real failure vs noise. It is the hard-won context that sits behind the
mechanics, not the mechanics themselves.

For the step-by-step deploy procedure, bypass env vars, and post-deploy
verification commands, see `docs/runbooks/RUNBOOK.md` (Deploy section),
`CLAUDE.md` (Releases + deploy doctrine), and `scripts/deploy.sh`. For how to cut
a release, see `CLAUDE.md` Releases and `scripts/release.sh`.

Two facts tie almost everything below together:

- **The CI runner and the live gateway are the same box.** Hydra's CI jobs run on
  a single self-hosted runner (`runs-on: [self-hosted, hydra]`) that *is* node-8,
  the production gateway host. So CI can be red because of live server state your
  diff never touched, and a careless test can clobber production fleet state.
- **Deploys rsync current `main`.** Every push to `main` auto-deploys. A later
  deploy of a superset carries earlier merged changes live regardless of whether
  an earlier run's smoke test flaked.

---

## Deploy

**Change live gateway config through the committed `openclaw-<profile>.json`, never an ad-hoc POSTSYNC mutation.** `sync_profile_config()` in `scripts/deploy.sh` syncs the committed `openclaw-<profile>.json` to `/root/.openclaw-<profile>/openclaw.json` (repo copy wins for every field except `.mcp.servers`, which is preserved from live). This is the reliable vehicle. Mutations stuffed into the `bash << 'POSTSYNC'` heredoc are fragile: that child shell runs `set -euo pipefail` through ~190 lines of AWS/kubectl/cron setup first, so any upstream failure aborts the block and a late mutation silently never runs. A 2026-05 incident left memory-search silently OFF on main for weeks because a POSTSYNC python block both targeted a phantom path (`/root/.openclaw/main/` missing the dash) and sat at the end of the heredoc.

**`RSYNC_EXCLUDES` has an unanchored `--exclude='config/'`, which swallows every `config/` at any depth.** It was meant to protect the dead legacy mirror at `/opt/hydra/config/`, but rsync matches unanchored patterns at every level, so `skills-all/<skill>/config/` never deploys and is invisible to the pre-flight drift gate. A 2026-06 watchdog failed closed every tick because its `deployments.txt` never shipped. When you add a NEW skill with a `config/` dir, you MUST add a per-skill `--include` pair ahead of the exclude (first match wins, unanchored so it covers both the repo->/opt/hydra and skills-all->profile-skills transfer roots), or the config silently won't deploy.

**A path that moves from rsync-excluded to included trips Step 0 drift on its FIRST deploy, and that is a false positive.** The server copy is just stale-by-exclusion (never synced while excluded), and because the authoritative change predates the deploy baseline, Step 0 misreads "server != HEAD and not in baseline..HEAD" as a direct server edit. Do NOT follow the block's auto-suggested `sync-from-server.sh --apply` runbook here: that pulls the stale server copy down into canonical and reverts your change. Data flows repo->server; the repo is authoritative. Clear it with `HYDRA_SKIP_DRIFT_CHECK=1 ./scripts/deploy.sh`, NOT `HYDRA_FORCE=1`: SKIP_DRIFT skips only Step 0 and keeps the Step 4a delete-guard active (strictly safer); FORCE skips both.

**Verify "is my change live" at the gateway's load path, not the rsync staging dir.** The gateway loads plugins from `/root/.openclaw-<profile>/extensions/<plugin>/dist/` and skills from `/root/.openclaw-<profile>/skills/<name>/`; config from `/root/.openclaw-<profile>/openclaw.json`. The rsync target `/opt/hydra/plugins/<plugin>/dist/` is build-staging and can be weeks stale, giving a false "fix not deployed" alarm. "Live" = the compiled file in `extensions/<plugin>/dist` carries the change AND the gateway's `ActiveEnterTimestamp` (`systemctl show openclaw-gateway-<profile> -p ActiveEnterTimestamp --value`) is later than the dist build mtime.

**Plugin install paths have drifted before, and hot-patching the wrong one reaches nothing.** An early `install_plugin()` wrote to the legacy unified `/root/.openclaw/extensions/`; the per-profile services actually load from `/root/.openclaw-<profile>/extensions/`. The bug was masked for weeks by a zombie legacy gateway that happened to load the legacy path, then surfaced the day that service died. If you hot-patch a plugin on node-8, rsync to `/root/.openclaw-<profile>/extensions/<plugin>/`, `chown -R root:root` afterward (rsync from a laptop carries uid=501, which the loader rejects as "suspicious ownership"), and move any `<plugin>.bak-*` dirs OUT of the extensions tree (the loader scans them as duplicate plugin-ids).

**Deploy restarts are drain-aware; the `--safe` deferral does NOT force-restart on 2026.6.1.** Step 6 asks the gateway to finish active work via `openclaw gateway restart --safe` (RPC → drain → SIGUSR1 self-exit(0) → systemd `Restart=always` brings it back; that unit setting exists for exactly this, PR #169) instead of SIGTERM-killing in-flight turns and undelivered replies. Live-probed 2026-07-13: idle → `"result":"scheduled"`, restart in ~15s; busy (24 active items) → `"result":"deferred"` and — despite upstream docs claiming a 5-min forced deadline — the request just persists until work actually drains (~12 min observed). So the client-side await budget in `scripts/lib/gateway-restart.sh` (`GATEWAY_DRAIN_DEADLINE_SECS`, 390s) + loud hard-restart fallback is the REAL forcing mechanism. Fallbacks Slack-notify; if that fires on every deploy, the safe path is broken — don't ignore it. `HYDRA_HARD_RESTART=1` restores the old immediate hard restart. Ignore the CLI's `gateway status` claim of "Service: systemd user" — that's a broken leftover symlink at `/root/.config/systemd/user/default.target.wants/openclaw-gateway.service`; the real units are system-level `openclaw-gateway-{main,edge}`. Re-verify `--safe` semantics on every openclaw bump.

**Two CD paths once existed; the `config/` exclude is load-bearing, do not remove it.** Historically `scripts/deploy.sh` (writes `/opt/hydra/`) and a GH Actions mirror (wrote `/opt/hydra/config/`) were unaware of each other, and deploy.sh's `rsync --delete` would have wiped the mirror. The `--exclude='config/'` is the guard. This is also the root of the unanchored-exclude gotcha above; keep both facts in mind when touching `RSYNC_EXCLUDES`.

---

## CI gates & the self-hosted runner

**Bats and shellcheck run on the LIVE gateway host, so tests must be hermetic about live paths.** Because `pr-validate.yml`'s bats/shellcheck jobs run on node-8 itself, a test that runs a real script reading or writing hard-coded live paths will read or clobber production fleet state on every CI run (one watchdog suite reset the live alert-cooldown clocks and read the real edge auth store). Rule: parameterize EVERY live path behind an env seam with a prod default, point it at a throwaway dir in `setup()`, and PATH-stub `systemctl`/`journalctl`/`openclaw`/`muso` so a test can't poke real services or page Slack.

**The shellcheck gate is `shellcheck --severity=warning <f>` from the repo root, over `scripts/` + `.githooks/` only.** Consequences: `info`-level findings (notably `SC1091` "Not following: ...") never gate, so don't chase them. CI passes no `-x`, so sourced files aren't followed; running `shellcheck -x` yourself surfaces SC1091 the gate never sees. To verify faithfully, run the exact command from repo root. Scripts under `workspaces/*/skills/` are NOT shellcheck-gated (they can carry pre-existing warnings), though the bats job DOES cover workspace skill tests.

**Python unit tests run by explicit module name, not `unittest discover`.** Each module is its own step (`python3 -m unittest -v tests.test_<x>`); discovery is deliberately avoided so it doesn't import the pytest-based outreach suite. A new `tests/test_*.py` does NOT run in CI until you add its own step to `pr-validate.yml`. The `py_compile` step only proves files parse; it runs no assertions. Wire the new module in the same PR.

**The PR-time Deploy pre-flight gate is STRICTER than the deploy it shifts left.** The gate runs `rsync -an --delete ./ /opt/hydra/` against the live server and fails on ANY surviving `*deleting` line, but `deploy.sh` Step 4a only BLOCKS deletions under `workspaces/`/`skills-all/` and merely LOGS others. So a PR that legitimately deletes an already-deployed tracked file (e.g. a script) flaps the gate red even though merging would deploy fine, and the result flaps with live server state. The durable fix is to merge the PR (the merge-deploy removes the file as a non-suspicious deletion and `main` stops shipping it). Transient bridge: `rm /opt/hydra/<path>` on node-8 + `gh run rerun <id> --failed`.

**Renaming/removing a fleet agent or moving tracked files (skills, docs) ripples across several gates.** Checklist: (1) two CI files hardcode the fleet workspace list, update BOTH - `pr-validate.yml` "SOUL.md check" `EXPECTED_WORKSPACES`, and `deploy.yml`'s change-detection `case` glob; also grep `.github/workflows/` + `scripts/` for any other hardcoded agent-name list. (2) CODEOWNERS is adk47-gated; a non-adk47 PR must NOT edit it (revert with `git checkout origin/main -- CODEOWNERS`). (3) the deploy pre-flight blocks any PR that deletes a server file; remove exactly the flagged paths on node-8 then rerun. (4) the `pr-title` check rejects `docs:` PRs touching non-doc files and `chore:` PRs touching `*/src/`, so a file-move that repoints code references must be `refactor:`/`feat:`/`fix:`.

**The rebase-staleness gate fires when you're behind main AND overlap a file main also changed.** A CI gate (added 2026-05) fails fast when your branch is N commits behind `main` and main touched a file your branch also touches, because GitHub's merge button does not refuse a behind PR and the squash-merge state is never CI-validated otherwise. Fix: `git fetch origin main && git rebase origin/main && git push --force-with-lease`. It is naive on overlap (any same-file overlap fails); this is intentional (errs safe).

### Red but not your fault

These are the known false-red signatures. Diagnose read-only, confirm it is not your diff, do not force shared gates.

- **Runner congested or down (repo-wide).** Checks sit `queued` with 0s duration and never start. Tell: `gh run list --repo Muso-AI/hydra --json status,workflowName,headBranch` shows OTHER branches and `main` all `queued` too, and `pr-title` (GitHub-hosted) is green while every self-hosted job hangs. Do NOT restart the shared runner or spam reruns; poll slowly (or arm a Monitor) and let it drain - it self-recovers.
- **Base-movement reds.** Another PR merged after you branched, so the rebase-staleness gate AND the deploy pre-flight "skills-all drift (SERVER-AHEAD)" both go red on a clean diff (the merged PR's skills are already on node-8 but absent from your branch). Fix BOTH with one `git fetch && git rebase origin/main && git push --force-with-lease`. Don't chase as diff bugs.
- **Smoke-test PONG / cron flake.** The post-restart smoke test (Step 7) runs AFTER rsync + restart already succeeded, and can fail transiently: `cron status returned nothing`, `agent did not return PONG within 60s`, `CLI port mismatch ... gateway is_active was already verified upstream`. If the same run shows gateways restarted and agents bound, it's a flake. Verify live bytes on node-8 or wait for the next superset deploy; don't trust the red run for "is it live".
- **QA scratch / SQL-redirect debris in the pre-flight.** The pre-flight wants to `*deleting` a stray file in `workspaces/qa/` (QA-bot review scratch, e.g. `tmp_*` or `tmp-pr<N>-review.md`) or bare files in `workspaces/devops/` named like JSON keys (`status`, `order-`, `items`, ...). The latter is debris from an agent running an unquoted Postgres `->`/`->>` query in bash (bash parses the arrows as redirections, splattering 0-byte files into the agent's cwd inside the synced tree). Confirm it's not in your diff (`git ls-files`, `git show --stat`, previous commit's pre-flight passed), get owner OK, `rm` only the verified debris on node-8, then `gh run rerun <id> --failed`. No new commit needed.
- **Locale wart (resolved 2026-06).** node-8's runner `.env` set `LANG=en_US.UTF-8` without the locale generated, so perl printed a "Setting locale failed" warning to stderr that bats merged into `$output`, breaking prefix assertions in CI only (passed locally and via plain SSH). Fixed with `locale-gen en_US.UTF-8`; if a node-8 rebuild loses it, re-run that. Repro: `env -i HOME=/root PATH=... LANG=en_US.UTF-8 bats <suite>`.

---

## PRs, approvals & the QA bot

**The QA auto-review is async and scope-guarded.** `qa-autoreview.yml` fires on the "PR Validation" `workflow_run` completing, then guards to `author == nsollazzo`, non-draft, base `main`. It dispatches a gateway agent that reviews and approves only if every CI check passed at the instant it checks. The dispatched agent finishes a few minutes after its trigger.

**"Green but COMMENTED, not APPROVED" is usually the mid-CI race, not a stuck bot.** If the agent reviews while any check is still pending, it records the GO verdict (sets the `qa-review` commit status green) but skips the formal APPROVED review, leaving the PR green-but-`REVIEW_REQUIRED`. The APPROVED typically lands ~1 min after CI goes fully green. Wait ~5 min past CI-green before concluding it's stuck. The reliable signal is the `qa-review` commit status on your PR head, which lands a beat before `reviewDecision` flips.

**A real NO-GO does NOT auto-re-review after you fix it; re-request the reviewer.** When the bot posts a blocking finding, GitHub removes adk47 from `reviewRequests` (a submitted review fulfills the request), so a later push re-runs CI but the bot stays silent. Nudge with `gh api repos/Muso-AI/hydra/pulls/<N>/requested_reviewers -X POST -f 'reviewers[]=adk47'`. Also check `review.commit_id == HEAD` before reacting to a finding; a stale COMMENTED review on a prior commit can re-flag something already fixed.

**`workflow_run` reports the run's headSha as main's tip, not your PR head.** So `gh run list --workflow qa-autoreview.yml` rows never match your PR commit by sha, and the run name/sha look like a different PR. Do NOT conclude "it didn't fire for me" from the sha; verify via the `qa-review` commit status on your head or the posted review's `commit_id`.

**The QA bot reviews AS the adk47 account, which is the CODEOWNER, so its APPROVED clears CODEOWNERS.** hydra `plugins/*` (and other paths) are CODEOWNERS-gated to adk47, but the bot's APPROVED satisfies that gate and flips `reviewDecision` to APPROVED with no human click. So babysit/ship CAN drive a CODEOWNERS-gated PR to APPROVED autonomously by addressing the bot's findings (a human still merges under ship's no-`--merge` default).

**adk47-AUTHORED PRs are the exception: no auto-review and the bot can't self-approve.** The dispatcher scope-skips non-nsollazzo authors, and even after a manual dispatch returns GO, `qa-pr-approve.sh` refuses with exit 4 (GitHub blocks adk47 approving an adk47 PR). These need a manual review dispatch (`bash /opt/hydra/scripts/qa-dispatch-pr-review.sh <PR> "$SHA"` on node-8) AND a different reviewer (e.g. nsollazzo) to approve.

**Approval-survives-push is INCONSISTENT here; verify `reviewDecision` live after any push.** The working model: any push that changes tree content vs the approved commit dismisses the approval (observed for merges, conflict-resolving rebases, and plain additive commits), while a conflict-free rebase that only re-parents identical content kept it once. Branch protection does NOT reliably enforce stale-review dismissal, so don't assume either way. Either way the cost is the same: after green the bot re-approves on its own (budget a full CI+QA cycle). Takeaway: only push to clear a thread when the user asks or for a blocking finding, never for an unprompted green.

**A REBASE WARNING thread is per-HEAD, and a human resolving it IS the ack — expect
one per rebase.** When PR Validation's rebase-integrity report is `WARN` (e.g.
`erased-recent-base-work`: the PR deletes lines main gained recently), each QA pass
files one head-tagged `🟡 REBASE WARNING [<sha7>]` thread and NO-GOes while it is
unresolved. The bot never resolves it itself — the author/human replying with
evidence ("these 3 deleted lines are #676's `:-/root` default; deleting it IS the
fix") and resolving the thread is the acknowledgment mechanism, not queue-clearing.
Every new head (rebase, merge-from-main) legitimately spawns a fresh thread for the
same signal; re-ack it. This is not the bot looping — check the `[sha7]` tag before
diagnosing a deadlock.

**QA verdicts race your replies/resolutions — judge by dispatch order, not arrival
order.** The auto-review is dispatched when PR Validation completes and reads thread
state minutes later; a NO-GO that lands after you resolved a thread often evaluated a
snapshot from before. Before reacting (or concluding the bot is stuck), compare the
review's `submittedAt` and covered head against your fix push / resolution time. The
recovery is always the same: threads resolved + fixes pushed → rerun PR Validation
(or push) → the next pass verifies, resolves confirmed-fixed threads itself, and
carries forward the rest.

**Budget for an adversarial multi-round QA gauntlet on privileged/infra code — and
answer findings with fixes, not arguments.** The DR-healer PR (#684, 2026-07-15) took
8 NO-GO rounds; every single finding was real (fail-open confidence typing, silent
degradation declared "healed", symlink attacks, SIGPIPE aborts, injection steering,
hung-lock absorption). The loop that converges: verify the claim against the code
(some findings overstate the mechanism — say so in the reply while still fixing the
reachable case), fix with a regression test that fails without the fix, reply
in-thread with the commit sha and test evidence, and let the bot's next pass resolve
its own threads. Each round is a full CI+QA cycle (~15–25 min); pipeline fixes for
the round, not one-at-a-time.

**A gateway restart (e.g. a deploy) silently kills an in-flight qa-review one-shot.** openclaw's own config-reload defers politely, but an external `systemctl restart` does not wait, leaving no run jsonl, no GitHub review, no Slack DM, and nothing re-dispatches it. If a review "went silent" (dispatch green but no adk47 review ~5 min later), check `journalctl -u openclaw-gateway-main` for a restart; recover with `gh run rerun <trigger-run-id> -R <repo>` on the source repo's trigger run.

---

## gh / git / worktree tooling

**`gh pr checks --watch` exit 0 is not trustworthy.** It can exit 0 ("all passed") on a transient all-clear when only a subset of checks has registered (e.g. right after a force-push, between two workflow runs). Never declare green on the watch exit code alone; re-confirm with a plain `gh pr checks <PR>` (and/or `gh pr view --json mergeStateStatus,statusCheckRollup`) and verify the head SHA the checks ran against matches HEAD. Empty `conclusion` fields are a related "not settled yet" tell.

**`gh pr merge` can 401 with otherwise-working auth; go straight to REST.** Reads and `gh api repos/...` work, `gh auth status` shows a valid `repo`-scoped token, but `gh pr merge --squash` returns 401 "Requires authentication". Workaround: `gh api -X PUT repos/Muso-AI/hydra/pulls/<n>/merge -f merge_method=squash` then `git push origin :<branch>`. Don't re-auth.

**`gh issue list` is eventually consistent; never use a list for "does X exist right now" right after creating X.** Label-filtered lists lag ~1-2s; unfiltered lists still have a sub-200ms read-after-write window. A "list existing -> if none, create" dedup duplicates on back-to-back creates. Fix is a local fingerprint ledger (all fleet callers run on node-8, so one on-disk ledger is authoritative) PLUS a `flock` around lookup->create->ledger-write (ledger closes the sequential race, flock the concurrent one). Single-issue `gh issue view <n>` IS read-after-write consistent.

**In a Superconductor worktree, local `main` lags `origin/main` and the PR head can change under you.** `git diff main` then shows other merged PRs' changes inverted as noise; always fetch and diff/rebase against `origin/main`. The PR branch head SHA can also flip to a `Merge branch 'main' into <branch>` commit mid-babysit without your pushing. Before declaring green, confirm local HEAD == remote PR head AND `git diff origin/main...HEAD` is still only your change.

**`/ship` and its cwd-bound skills cannot target a repo other than the session's worktree.** The harness force-resets the Bash cwd to the SC worktree after every Bash call, so `simplify`/`code-review`/`verify`/`smart-commit`/`babysit`-fix would run git against the wrong (or empty) repo and falsely report "shipped". The same trap applies across SIBLING worktrees of the same repo (a branch checked out elsewhere refuses `git checkout`). Drive cross-repo/cross-worktree work with explicit flags: `git -C <path>` for diff/commit/push, `gh pr ... -R owner/repo`, and `babysit <PR#> owner/repo`. Meet each cwd-bound stage's GOAL directly (run the target repo's tests by absolute path, use an adversarial subagent pass for review).

**Don't invent GitHub labels; `gh issue create --label` rejects unknown labels and fails the whole call.** hydra's custom labels are `urgent`, `chore`, `recurring`, `P0`-`P3`, `multi-gateway-cleanup`, plus the stock set (`bug`, `documentation`, `enhancement`, `wontfix`, ...). There is NO `tech-debt` label; use `chore` + `P2`/`P3`. Re-check with `gh label list --repo Muso-AI/hydra --limit 50`.

---

## Infra topology & access

**SSH to the box.** `ssh -i ~/.ssh/nick_ovh root@40.160.32.80` (hostname `ovh-node-8`). This single box is both the self-hosted CI runner AND the live gateway host, which is why CI red can mean live server state and why tests must be hermetic.

**External `*.muso.ai` traffic is served by k8s Traefik, not host Caddy.** Cilium socket-LB intercepts the connection at the eBPF socket layer and routes it to k8s Traefik (which terminates TLS and routes by `Ingress` rules); host Caddy on `:443` is only reachable by loopback. So the `/etc/caddy/Caddyfile` is the wrong place to debug a production URL. An `Ingress` whose backend `Service` does not exist silently returns `404 page not found` from Traefik with no native warning. Probe pattern: `curl https://<host>/<path>` (401 HMAC-reject = healthy webhook, 404 = routing broken) -> `kubectl describe ingress -n hydra <name>` (look for `services "X" not found`) -> `curl http://localhost:<port>/<path>` on node-8. `scripts/smoke-test.sh` runs an Ingress->Service consistency check on every deploy.

**Cluster/infra/CI-health work is tracked canonically in `Muso-AI/H-DevOps`, not hydra.** hydra sometimes carries "visibility copies" whose body says so. When a hydra issue is really about k8s Ingress/Service, Traefik, prod-manifest reconciliation, the `Health:*`/smoke workflows, or external DNS, the real fix lands in H-DevOps; point at the canonical issue rather than fixing it in hydra. See also `H-DevOps:docs/MAJOR-FAILURES-TRACKER.md`.
