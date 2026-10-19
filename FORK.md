# Fork features

This fork (`adk47/firstmate`) tracks upstream [`kunchenguid/firstmate`](https://github.com/kunchenguid/firstmate) and carries the local changes below.
Each row names the owner file, why the fork keeps it, and whether it is meant to go upstream.
Keep this table current in the same change that adds, removes, or upstreams a fork feature.

| Feature | Owner | Why the fork keeps it | Upstream status |
| --- | --- | --- | --- |
| No-fork status-log fold, timestamp-first status lines, bounded reads | `bin/fm-classify-lib.sh` | Upstream's per-line fold forks a subshell per line; multi-megabyte lane logs made drains and session start take minutes | Candidate PR |
| Fleet-size watcher liveness and restart attach | `bin/fm-watch.sh`, `bin/fm-watch-arm.sh`, `bin/fm-wake-lib.sh` | Polls of ~80 tasks aged the beacon past its grace | Candidate PR |
| Bounded heartbeat folds, snapshot deadline, single-flight home summary | `bin/fm-watch.sh`, `bin/fm-fleet-snapshot.sh`, `bin/fm-home-summary-refresh.sh` | Fleet-size stalls of the heartbeat and snapshot | Candidate PR |
| Stale per-task lock reaper and coalesced steering ticks | `bin/fm-lock-reap.sh`, `bin/fm-wake-lib.sh`, `bin/fm-send.sh` | Locks stranded by killed holders refused sends; undrained periodic ticks piled up | Candidate PR |
| Python fleet-snapshot per-task pass | `bin/fm-fleet-snapshot.py` | The per-task bash pass took minutes at fleet size; `FM_SNAPSHOT_IMPL=bash` keeps the original | Candidate PR |
| Fork-free wake drain stat cache | `bin/fm-classify-lib.sh`, `bin/fm-wake-drain.sh` | One `stat` per status log per section cost thousands of forks per drain | Candidate PR |
| Fleet stall watch | `bin/fm-fleet-stall-check.sh` | A gateway outage stalled many workers at once while each read as its own business | Fork-only until upstream has a fleet-level stall signal |
| Bounded session-start backlog reconcile and test worker reaping | `bin/fm-bootstrap.sh`, `bin/fm-test-reap-lib.sh` | Per-record backlog reads made bootstrap take minutes on a large home; leaked test workers outlived their suites | Candidate PR |
| Tool-update wakes deduped by finding identity | `bin/fm-tool-update-check.sh` | Reworded findings re-woke firstmate | Candidate PR |
| Pi wake fold under an unconsumed follow-up | `.pi/extensions/fm-primary-pi-watch.ts` | Stacked follow-up doorbells | Candidate PR |
| Orca recovery-grade agent-state classifier | `bin/backends/orca.sh` | Orca's sticky agent identity cannot prove an agent exited; the pane's process tree can, so `exit` works on Orca | Candidate PR |
| Orca relaunch of a terminal Orca proves gone | `bin/fm-spawn.sh`, `bin/fm-control-lib.sh`, `bin/backends/orca.sh` | Orca tasks could not be resumed after a host or Orca restart; absence needs the classifier's stale handle and a complete host-wide terminal inventory | Candidate PR |
| Gateway-503 keep-alive | `bin/fm-gateway-retry-lib.sh`, `docs/gateway-keepalive.md` | Workers idled by a pooled-gateway 503 were escalated as wedges | Candidate PR |
| `/roster` fleet matrix | `bin/fm-roster.sh`, `.agents/skills/roster/` | Captain-requested fleet view | Candidate PR |
| Sentry watch | `bin/fm-sentry-watch.sh` | Muso production alerting | Fork-only until upstream has a generic armed-check liveness line |
| Post-merge change watch | `bin/fm-change-watch.sh` | Kubernetes deploy regression watch | Fork-only until upstream has a post-merge hook |
| DeepSeek lane gateway and lane model switch | `bin/fm-deepseek-gateway.sh`, `bin/fm-lane-model-switch.sh`, `docs/deepseek-lane-gateway.md` | Serves DeepSeek V4.1 Flash to Claude Code lanes | Fork-only |
| Firstmate chair sentinel and flip | `bin/fm-chair-*.sh` | Pi+Fable to SuperGrok supervisor failover | Fork-only |
| Fable runway monitor | `bin/fm-fable-runway*.sh`, `docs/runbooks/supervisor-failover-grok.md` | Wakes before the Fable supervisor runs out | Fork-only |
| House-wiki stanza and worker `lesson:` rule | `bin/fm-house-wiki-stanza.txt`, `bin/fm-brief.sh`, `bin/fm-session-start.sh`, `AGENTS.md` | Muso house knowledge lives in `~/.llm-wiki`, and workers report lessons through their `done:` or `failed:` line | Fork-only |

Dropped from the tracked tree:

- The no-mistakes 1.75.2 note (`docs/tool-updates/no-mistakes-1.75.2.md`) evaluated an upgrade to 1.75.2.
  The installed no-mistakes is already newer (the v1.64.0+fm.1 fork build tracking upstream, with v1.84.0 available), so the evaluation no longer describes a pending decision.
