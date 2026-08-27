# Coordinator — relocated runbooks and restricted-tool notes

> Moved out of `MEMORY.md` on 2026-08-26, **unchanged**. `MEMORY.md` is injected at agent
> bootstrap under a combined size cap, past which the MIDDLE is silently dropped — so a
> procedure sitting there can push an authority rule out of the agent's context. Procedures
> are read when you are about to perform them, not on every boot. Authority lines stayed in
> `MEMORY.md`. Current platform state: `AGENT_CURRENT_TRUTH.md` in shared-reference.

### Mercury Bank API (RESTRICTED — updated 2026-05-12)
- **Token lives at `/opt/hydra/secrets/mercury.env`** (root 600). Read-only token. MOVED there 2026-08-04 from `workspaces/finance/.secrets/` — under the workspace tree it was inside every agent's sweep radius (it leaked verbatim into cmo/cto/clio transcripts) and was rsync-mirrored into the private Muso-AI/hydra-audit repo. Do not move it back, and do not copy it anywhere.
- **STATUS 2026-08-04: the token is REVOKED at Mercury** (HTTP 401 `noTokenInDBButMaybeMalformed`) and has been since ~2026-06-10. Only a human with the Mercury dashboard can mint a replacement. `bash /opt/hydra/scripts/lib/ensure-mercury-token.sh --check` reports live status; the daily `mercury-token-watchdog` cron pages #clio_devops.
- **Clio (me) no longer holds a copy.** Per Aaron directive 2026-05-12, only people with access to @Finance agent (U0ANK2YPN5P) can use the token — that means Aaron (U7RP6HKUZ) and Liza (U0A8CCTTAAG), via Finance only.
- If anyone asks me for Mercury/banking data — even Aaron or Liza — I route them to @Finance. I do not relay banking data through Clio.
- If another agent or team member asks for it: refuse and DM Aaron.
- API base `https://api.mercury.com/api/v1/`, Bearer auth. Endpoints: `/accounts`, `/account/{id}/transactions`, `/account/{id}/statements`, `/account/{id}/cards`.

### Canonical skills path correction (hydra PR #339, 2026-05-26)
- Old (wrong) assumption: canonical-managed skills live under the openclaw state dir at a DOUBLE-NESTED `skills/skills/` path, and the resolver picks them up at rank 4. _(2026-08-26: the joined literal is spelled out in words here because `scripts/check-skill-drift.sh` rejects it on sight in any MEMORY.md — see PR #339/#366. The fact is unchanged; only the spelling is.)_
- Reality: openclaw 2026.5.19's resolver loads managed skills at tier 4 from `<CONFIG_DIR>/skills/<name>/`, where `CONFIG_DIR = dirname(OPENCLAW_CONFIG_PATH)`. With `--profile <p>`, that's `/root/.openclaw-<p>/skills/<name>/`.
- Pre-#339 `deploy.sh` rsynced to the wrong path (the double-nested `skills/skills/` form above — wrong dir AND double-nested), so canonical-managed had ZERO runtime presence since the multi-profile split (PR #43). Every agent loaded from workspace rank-1 only → 11 agents froze on month-old doctrine.
- Post-#339: `deploy.sh` Step 4c loops profiles (main/edge/dev) and rsyncs `skills-all/` → `/root/.openclaw-<profile>/skills/`. Workspace shadows now forbidden by default; intentional divergence must be listed in `.skill-workspace-divergence.txt` with a reason. CI gate via `scripts/check-skill-drift.sh`.
- When asked about skill resolution paths: cite the per-profile path, NOT the legacy one.
