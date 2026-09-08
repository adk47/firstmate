# scripts/aux-units/

Reference templates for the systemd units installed by `scripts/install-aux-units.sh`.

These files are **not** the source of truth at install time — `install-aux-units.sh` writes the unit content inline via heredocs so it can substitute `$HYDRA_ROOT` and other deploy-specific values. The files here exist so PR reviewers can see the intended unit shape without reading shell heredocs, and so a human editing a unit on node-8 (`systemctl edit ...`) has a clean reference to copy from.

If you change a unit shape, update **both** the template here and the heredoc in `install-aux-units.sh`. The pre-commit hook does not (yet) verify they're in sync.

## Inventory

- `openclaw-gateway.override.conf` — drop-in for `openclaw-gateway-{main,edge,dev}.service`. Adds `ExecStartPre` self-heal + a restart ceiling so a corrupt config can't crash-loop indefinitely.
- `openclaw-config-write-audit@.path` — template-instance inotify watch. One instance per profile (`@main`, `@edge`), each watching exactly one `openclaw.json`. Pre-2026-05-12 there was a singleton `.path` watching both profiles; it produced cross-profile false-positive alerts on every deploy.
- `openclaw-config-write-audit@.service` — triggered by the matching `@.path` instance; runs the audit logger against the specific profile's `openclaw.json` and Slack-alerts on non-gateway writers.
- `tmp.conf` — `/etc/tmpfiles.d/tmp.conf`, the node-8 `/tmp` age policy keyed on mtime only (`D /tmp 1777 root root mM:14d`). Unlike the units above this one IS the source of truth: `install-aux-units.sh` installs it verbatim (no substitutions) and refuses a version without the `mM:` prefix, because a plain age is silently defeated by the nightly atime refresh (2026-08-26 node-8 disk-pressure root cause).
