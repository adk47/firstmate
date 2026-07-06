# Vendored ship-kit skills

The skills `ship`, `babysit`, `smart-commit`, `reflect`, `simplify`, `verify`,
`code-review`, `triage`, and `fix` under `skills-all/` are **vendored verbatim**
from ship-kit — a portable Agent-Skills bundle. They are not authored here; treat
them as a read-only mirror of upstream so the kit stays a single source of truth
and stays upgradable.

- **Upstream**: https://github.com/nsollazzo/ship-kit
- **Vendored commit**: `059b4eb655a70ce75881c42632374a3174a3f254` (v2.2.0)
- **Source path in upstream**: `.agents/skills/<name>/SKILL.md`
- **Vendored on**: 2026-06-25

`triage` is a **multi-file** skill (alongside `SKILL.md` it ships
`defense-in-depth.md` and `root-cause-tracing.md`); the re-vendor loop `cp -R`s
the whole dir so those ride along, the deploy Step-4c whole-tree rsync carries
them, and `scripts/check-skill-drift.sh` keys only on `SKILL.md` so the helpers
don't trip it.

## Why these are here

The **CTO** agent drives every code change's commit → PR → green flow through
ship-kit's `ship` pipeline (see `skills-all/cto-codex-coding/SKILL.md`). `ship`
chains six of these skills by their canonical names (`simplify`, `verify`,
`code-review`, `smart-commit`, `babysit`, `reflect`), so they must be present
under those exact names for its stage-dispatch to resolve. `skills-all/` is
hydra's canonical skill tree (deploy.sh Step 4c rsyncs it to every profile's
managed-skills dir), so vendoring here makes them available to the fleet; only
cto's doctrine actually drives the pipeline.

`triage` (read-only diagnosis) and `fix` (triage → branch → implement → `ship`)
are v2.2.0's standalone additions — not chained by `ship`, but vendored live at
Nick's request.

## `fix` is live, with a mechanical audit guard

`fix` is a write-path: its description triggers on "fix this bug" / "debug and
fix" — the same prompts `cto-codex-coding` answers — and on its own it cuts a
`fix/…` branch and ships **without** CTO's audit row, push-access check,
`cto/<slug>-<ts>` branch rail, or QA handoff. So CTO must enter every code change
through `cto-codex-coding`, never via standalone `fix`. Two layers enforce that:

1. **Doctrine (the entry point).** `cto-codex-coding` and `workspaces/cto/SOUL.md`
   name `fix`/`triage` as never an entry point; coding always enters
   `cto-codex-coding`. This layer is necessarily prose — openclaw (2026.6.1) has
   **no per-agent skill exclude/denylist** (only a flat `agents.list[].skills`
   allowlist that *replaces* auto-discovery — fragile — or a fleet-wide
   `skills.entries.<name>.enabled:false` that would disable `fix` for every agent).
   It's an acceptable layer on its own: cto (Codex) *chooses* its skill from
   descriptions + doctrine (there is no blind pre-agent router), and it could
   already hand-invoke the vendored `ship` directly today — `fix` is the same trust
   class, not a new one.
2. **Mechanism (the git boundary).** Most of the rail does **not** rest on doctrine.
   At deploy time `scripts/lib/setup-cto-clone-hooks.sh` (run from
   `install-aux-units.sh`) arms a **directory-scoped** git `core.hooksPath` —
   `includeIf "gitdir:/opt/hydra/workspaces/repos/"` — so a pre-push hook
   (`scripts/lib/cto-push-audit-guard.sh`) covers **every** clone under that dir,
   no matter which skill (`fix`/`ship`/`cto-codex-coding`/hand) created it or runs
   the push. The hook refuses a push unless **both** rails it can check at the git
   boundary hold: (a) a recent CTO **audit row** exists for the repo, and (b) the
   pushed branch is a **`cto/<slug>`** branch — never a default branch, never a
   `fix/…`/other. So even a stray `fix`/`ship` entry that wrote an audit row is
   still rejected for pushing a `fix/…` branch. Arming it out-of-band at deploy time
   (not per-clone inside `cto-codex-coding`) is what makes it airtight: a clone the
   bypassed path never set up is still covered. Scoped to CTO's clones, so no other
   agent or human checkout is affected. Tests:
   `scripts/tests/{cto-push-audit-guard,setup-cto-clone-hooks}.bats`.

   The one CTO rail a git hook **can't** enforce is the **@QA handoff** (a Slack
   action, not a git operation) — it stays doctrine. Its failure mode is benign: a
   PR that opens without a requested review just stalls (babysit waits); it never
   produces an unsafe merge. That residual is accepted.

`yolo` (hands-off autonomous mode) is the one v2.2.0 skill we do **not** vendor —
an even broader write-path wildcard for a god-mode agent, and unneeded (CTO already
gets the `ship --yolo` *flag*, which lives in the vendored `ship` skill, to
auto-confirm ship's Stage-6 checkpoint — never `ship --merge`). See `cto-codex-coding`.

## Updating to a newer ship-kit

Re-vendor — do **not** hand-edit the bodies (that would fork upstream), and do
**not** add `yolo` (see above):

```bash
git clone https://github.com/nsollazzo/ship-kit /tmp/ship-kit
# from the hydra repo root:
for s in ship babysit smart-commit reflect simplify verify code-review triage fix; do
  rm -rf "skills-all/$s" && cp -R "/tmp/ship-kit/.agents/skills/$s" "skills-all/$s"
done
# then update the "Vendored commit" SHA above to /tmp/ship-kit's HEAD
```

> ⚠️ Do **not** use ship-kit's own `bin/install.sh` to vendor here. At `059b4eb`
> it loops over `.agents/skills/*` and copies **every** bundled skill — including
> `yolo` — which would silently add the one skill we intentionally exclude. Use
> the explicit 9-skill loop above.

After re-vendoring, prove fidelity — this should print nothing:

```bash
for s in ship babysit smart-commit reflect simplify verify code-review triage fix; do
  diff -r "skills-all/$s" "/tmp/ship-kit/.agents/skills/$s"
done
```

## Local divergence from upstream

Bodies and frontmatter of the nine vendored skills are byte-identical to the
vendored commit. The only intentional divergence is the **omission** of upstream's
standalone `yolo` (rationale above).

> If a future node-8 runtime check shows a bundled skill cannot use `exec`
> (openclaw tool-grant), the **only** permitted local change is adding
> `allowed-tools: [exec]` to that skill's frontmatter (matching
> `cto-codex-coding`). Record any such addition here so the next re-vendor
> reapplies it. As of the vendored commit, none was needed.
