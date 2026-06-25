# Vendored ship-kit skills

The skills `ship`, `babysit`, `smart-commit`, `reflect`, `simplify`, `verify`,
and `code-review` under `skills-all/` are **vendored verbatim** from ship-kit —
a portable Agent-Skills bundle. They are not authored here; treat them as a
read-only mirror of upstream so the kit stays a single source of truth and stays
upgradable.

- **Upstream**: https://github.com/nsollazzo/ship-kit
- **Vendored commit**: `5c453b20c02d70254fbc7149ce0dc345b2eca168`
- **Source path in upstream**: `.agents/skills/<name>/SKILL.md`
- **Vendored on**: 2026-06-24

## Why these are here

The **CTO** agent drives every code change's commit → PR → green flow through
ship-kit's `ship` pipeline (see `skills-all/cto-codex-coding/SKILL.md`). `ship`
chains the other six skills by their canonical names, so they must be present
under those exact names for its stage-dispatch to resolve. `skills-all/` is
hydra's canonical skill tree (deploy.sh Step 4c rsyncs it to every profile's
managed-skills dir), so vendoring here makes them available to the fleet; only
cto's doctrine actually drives them.

## Updating to a newer ship-kit

Re-vendor — do **not** hand-edit the bodies (that would fork upstream):

```bash
git clone https://github.com/nsollazzo/ship-kit /tmp/ship-kit
# from the hydra repo root:
for s in ship babysit smart-commit reflect simplify verify code-review; do
  rm -rf "skills-all/$s" && cp -R "/tmp/ship-kit/.agents/skills/$s" "skills-all/$s"
done
# then update the "Vendored commit" SHA above to /tmp/ship-kit's HEAD
```

(ship-kit's own `bin/install.sh --dest <dir>` does the same copy if preferred.)

## Local divergence from upstream

None. Bodies and frontmatter are byte-identical to the vendored commit.

> If a future node-8 runtime check shows a bundled skill cannot use `exec`
> (openclaw tool-grant), the **only** permitted local change is adding
> `allowed-tools: [exec]` to that skill's frontmatter (matching
> `cto-codex-coding`). Record any such addition here so the next re-vendor
> reapplies it. As of the vendored commit, none was needed.
