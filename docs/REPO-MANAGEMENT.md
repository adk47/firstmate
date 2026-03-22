# HYDRA Repo Management Strategy

## Dependency Management

### OpenClaw (core runtime)
- **Current**: v2026.3.13 (npm global install)
- **Update strategy**: Pin version in `package.json`, test in dev before promoting to prod
- **Breaking changes**: OpenClaw config schema changes can break `openclaw.json`. Before updating:
  1. Backup current `openclaw.json`
  2. Run `openclaw doctor` on the new version against our config
  3. Fix any schema violations
  4. Test in shadow mode (Week 4 parallel run pattern)
- **Config preservation**: `openclaw.json` is version-controlled in this repo. Never update OpenClaw and config simultaneously.

### NemoClaw (security sandbox)
- **Current**: v0.1.0 (alpha)
- **Problem**: NemoClaw's `onboard` deploys its own K3s cluster inside Docker, conflicting with our existing 8-node K3s cluster
- **Approach**: Use NemoClaw's Landlock/seccomp/netns policy engine WITHOUT its orchestrator
  - Extract `nemoclaw-blueprint/policies/` for filesystem and network policies
  - Apply Landlock rules directly via Linux kernel APIs or systemd sandboxing
  - Apply netns rules via iptables/nftables per the `egress-allowlist.yaml`
  - Skip `nemoclaw onboard` entirely — it's designed for standalone deployments
- **Tracking**: Watch https://github.com/NVIDIA/NemoClaw for releases. When they support "bring your own cluster" mode, adopt it.

### CLIProxyAPI (model proxy)
- **Current**: v6.9.0 (Docker `eceasy/cli-proxy-api:latest`)
- **Update strategy**: Pin Docker image digest, not `:latest`. Test new versions against Claude API.
- **Token management**: OAuth tokens in `/root/.cli-proxy-api/` auto-refresh. No manual rotation needed unless account-level revocation.

## Version Pinning

```
# versions.json — source of truth for all dependency versions
{
  "openclaw": "2026.3.13",
  "nemoclaw": "0.1.0",
  "cliproxyapi": "6.9.0",
  "k3s": "v1.34.5+k3s1",
  "node": "22.22.1"
}
```

## Update Workflow

1. **Dependency update detected** (Dependabot, manual check, or team notification)
2. **Create branch**: `update/openclaw-2026.3.14`
3. **Test locally**: Run `openclaw doctor` against current config
4. **Fix config**: If schema changed, update `openclaw.json`
5. **PR with CI validation**: `pr-validate.yml` checks JSON lint, SOUL.md presence, deny-list immutability
6. **Deploy to staging** (future: shadow mode on Node 8)
7. **Merge + CD**: `deploy.yml` pushes to Node 8, restarts gateway, smoke tests
8. **Rollback if needed**: `scripts/rollback.sh`

## What Goes Where

| Content | Location | Why |
|---------|----------|-----|
| OpenClaw config | `openclaw.json` (secrets redacted) | Version-controlled, secrets via Vault references |
| Agent workspaces | `workspaces/{agent}/` | SOUL.md, AGENTS.md, TOOLS.md, USER.md |
| Policies | `policies/` | Tool deny lists, egress allowlists |
| Scripts | `scripts/` | Deploy, rollback, smoke test, provisioning |
| K8s manifests | `H-DevOps/k8s/prod/hydra/` (separate repo) | Infra-as-code in the infra repo |
| Skills | NOT in this repo | Too large (47 skills, ~17MB). Synced from Clio-KB/muso-skills repos |
| Secrets | NEVER in this repo | Vault at `secret/muso-prod/hydra-*` |
| Audit logs | `Muso-AI/hydra-audit` (separate repo) | Append-only, Aaron-only |

## NemoClaw Integration Plan (When Ready)

When NemoClaw supports "bring your own cluster" or standalone sandbox mode:

1. Use `openshell sandbox create` to wrap the OpenClaw gateway process
2. Apply filesystem policies from `nemoclaw-blueprint/policies/openclaw-sandbox.yaml`
3. Apply network policies from our `policies/egress-allowlist.yaml`
4. Landlock enforces SOUL.md/AGENTS.md/TOOLS.md as truly read-only (kernel level, not just chmod)
5. seccomp blocks dangerous syscalls (exec, ptrace, mount)
6. netns isolates each agent's network access per the egress allowlist

Until then, we use:
- File permissions (chmod 444 on policy files)
- iptables firewall (default deny inbound)
- Cilium network policies in K8s
- OpenClaw's built-in tool deny lists (behavioral enforcement)

## Monitoring for Breaking Changes

- **GitHub Watch**: Star + watch NVIDIA/NemoClaw and OpenClaw repos for releases
- **npm audit**: Weekly `npm audit` on openclaw and nemoclaw packages
- **Config drift detection**: Compare running `openclaw.json` on Node 8 against repo version daily
- **Smoke tests**: `scripts/smoke-test.sh` validates all 9 agents respond after any update
