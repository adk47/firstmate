# scripts/aux-units/

Reference templates for the systemd units installed by `scripts/install-aux-units.sh`.

These files are **not** the source of truth at install time — `install-aux-units.sh` writes the unit content inline via heredocs so it can substitute `$HYDRA_ROOT` and other deploy-specific values. The files here exist so PR reviewers can see the intended unit shape without reading shell heredocs, and so a human editing a unit on node-8 (`systemctl edit ...`) has a clean reference to copy from.

If you change a unit shape, update **both** the template here and the heredoc in `install-aux-units.sh`. The pre-commit hook does not (yet) verify they're in sync.

## Inventory

- `openclaw-gateway.override.conf` — drop-in for `openclaw-gateway-{main,edge,dev}.service`. Adds `ExecStartPre` self-heal + a restart ceiling so a corrupt config can't crash-loop indefinitely.
- `openclaw-config-write-audit.path` — inotify watch on the three live `openclaw.json` paths.
- `openclaw-config-write-audit.service` — triggered by the `.path` unit; runs the audit logger and Slack-alerts on non-gateway writers.
