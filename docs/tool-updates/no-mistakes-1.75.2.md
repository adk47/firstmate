# no-mistakes v1.75.2 upgrade evaluation

Verdict: **GO**.

This record evaluates upgrading the no-mistakes gate from the installed v1.64.0 (2026-09-03) to the then-current stable release v1.75.2 (2026-09-14), and it carries the exact upgrade, the guard that must hold before the upgrade is applied, and the rollback.
It is a maintainer-verification record: dated empirical facts plus the exact commands that produced them.
`docs/configuration.md` "Watched tool updates" owns how a home notices that a newer release exists.

## What was evaluated

- Installed at evaluation time: `no-mistakes version v1.64.0 (d3fd004) 2026-09-03T10:29:32Z`.
- Target: `no-mistakes version v1.75.2 (4debd42) 2026-09-14T06:41:58Z`, the newest non-prerelease release then published.
- Stable releases crossed: v1.70.1 (2026-09-07), v1.72.0 (2026-09-08), and v1.75.2 (2026-09-14).
  The prerelease train v1.65.0 through v1.75.1 sits between them, and its changes ship inside v1.75.2.
- The target was fetched as the release asset `no-mistakes-v1.75.2-darwin-arm64.tar.gz` and verified against the release's own `checksums.txt`: `sha256 d4388422e773f7ef5e9c87afb35c1e3be0d572c8c8940f54fe6238e88366f2d3`.
- It was run from a scratch directory under its own `NM_HOME`, so neither the installed binary nor the shared daemon was replaced, and the scratch daemon, its `launchd` label, and the user-level skill copy it installed were removed or restored afterwards.

## Breaking changes

None are documented in the range.
`CHANGELOG.md` at v1.75.2 has no entry for a breaking change, a deprecation, a migration, or a removal between v1.64.0 and v1.75.2.

Every configuration key this repo's tracked `.no-mistakes.yaml` sets still exists at v1.75.2 with the same type and meaning: `disable_project_settings`, `document.instructions`, `commands.lint`, `commands.test`, and `test.evidence.store_in_repo`.
No configuration key was removed in the range.

New configuration keys in the range are all optional and default to the behaviour this repo already has:

- `pr.template`, `pr.publish_intent` (default `true`, which is the current published-`Intent`-section behaviour), `pr.title_format`.
- `commands.prepare`, which runs once per worktree before the configured test and lint commands.
- `gates`, an extra repository-declared command step (empty by default).
- `protected_paths`, which refuses an automatic commit that touches a listed path (empty by default, and a refusal always needs an explicit response even under AXI `--yes`).
- `test.instructions`, `test.allow_approve_over_failure`.
- `commit.branch_pattern`, `review_agents`, and `providers.<provider>.draft_pull_requests`.

## The pipeline attestation contract this repo's PR gate depends on

`CONTRIBUTING.md` requires human-authored pull requests to `main` to carry both the no-mistakes signature line and a parseable structured attestation, and `.github/workflows/no-mistakes-required.yml` enforces that with `kunchenguid/no-mistakes/.github/actions/require-no-mistakes@32d396ac0f29135daf7fcb9964aba9d5f4e796d6`.
`bin/fm-bootstrap.sh` owns the other half of that contract: `NO_MISTAKES_MIN=1.46.0` is the release that introduced the structured attestation, and v1.75.2 stays far above that floor.

The pinned action's `verify.py` requires, in order, the signature line `Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)`, exactly one `<!-- no-mistakes-pipeline-attestation:v1 {...} -->` comment whose `head_sha` equals the commit the forge currently has as the PR head, and `status: "completed"` for each of `review`, `test`, and `document`.

v1.75.2 keeps that contract:

- `docs/src/content/docs/reference/pipeline-steps.md` at v1.75.2 states that the `v1` payload and its required `head_sha` and `steps` fields are stable, and that the newer `live_validation`, `steps[].override_reason`, and `allow_test_command_override` fields are additive and omitted when empty, so older attestations remain valid.
- Both the installed v1.64.0 binary and the v1.75.2 binary embed the same signature marker and the same `no-mistakes-pipeline-attestation:v1` prefix, along with the `head_sha`, `steps`, `status`, and `completed` keys the validator reads.
- The pinned validator itself was run against a real attestation this fleet produced and reported it compliant (see "Local verification").

One hardening consequence is worth recording.
v1.75.2 records `steps[].override_reason` on a Test step that was approved over a failing configured `commands.test`, and the current upstream action treats that as non-compliant unless the trusted `test.allow_approve_over_failure` reason is set.
The action this repo pins predates that check, so it ignores the new field and the repo's gate behaviour is unchanged by the upgrade.
Adopting the stricter check is a separate decision, because it also requires adding `test.allow_approve_over_failure` to the trusted default-branch copy of `.no-mistakes.yaml`.

## Behaviour changes worth knowing

These are the changes in the range that touch how this fleet drives the gate rather than what it configures.

- The Test step now always invokes an evidence agent that drives named end-user scenarios against the real product, and it records a `go`, `no-go`, `inconclusive`, or `no-surface` verdict.
  An `inconclusive` verdict, and a `no-surface` verdict for a change with no runtime surface such as a docs-only or CI-workflow-only change, each add an `ask-user` warning and park the step for a decision.
  v1.64.0 has no live validation at all, so this is the single largest behaviour change in the range and the one most likely to add supervisor-facing decisions.
- `axi run` and `axi respond` gained `--wait` (default `8m0s`), which bounds how long they block before returning so a caller can reattach, and a returned wait is documented as not a failed run.
  A worker driving a run must inspect `axi status` and reattach rather than read an early return as a failure.
- `--yes` now auto-resolves eligible gates only, and a protected-path refusal requires an explicit response even with `--yes`.
  Firstmate bans `--yes` fleet-wide, so this narrows a path the fleet already avoids.
- `axi run` gained `--launch-nonce` with `--validation-generation` for strict proof mode, and `axi sync` gained `--bind-archive-ref` plus a redefined `--keep-local` that anchors available preserved commits and discards genuinely missing ones.
- `axi logs --step` now also accepts a repository gate step name.
- Several defects this fleet has actually hit are fixed in the range, including branch custody recovery from bound archives and preserved heads, AXI staying attached to a slow daemon, daemon login-shell environment resolution, dependency preparation once per run, CI failures unified with the findings loop, and honest token accounting on failed and cancelled invocations.

## Local verification

Exact commands and their exact output.

```sh
curl -fsSL -O https://github.com/kunchenguid/no-mistakes/releases/download/v1.75.2/no-mistakes-v1.75.2-darwin-arm64.tar.gz
curl -fsSL -O https://github.com/kunchenguid/no-mistakes/releases/download/v1.75.2/checksums.txt
shasum -a 256 no-mistakes-v1.75.2-darwin-arm64.tar.gz
# d4388422e773f7ef5e9c87afb35c1e3be0d572c8c8940f54fe6238e88366f2d3  no-mistakes-v1.75.2-darwin-arm64.tar.gz
grep darwin-arm64 checksums.txt
# d4388422e773f7ef5e9c87afb35c1e3be0d572c8c8940f54fe6238e88366f2d3  no-mistakes-v1.75.2-darwin-arm64.tar.gz
```

The target was then run against a scratch clone of this repo's tracked files, with its own `NM_HOME` so the shared root was untouched.

```sh
NM_HOME=$SCRATCH/home NO_MISTAKES_NO_UPDATE_CHECK=1 $SCRATCH/bin/no-mistakes --version
# no-mistakes version v1.75.2 (4debd42) 2026-09-14T06:41:58Z

cd $SCRATCH/repo && NM_HOME=$SCRATCH/home NO_MISTAKES_NO_UPDATE_CHECK=1 $SCRATCH/bin/no-mistakes init
#   ✓ Gate initialized
#     repo  /private/tmp/nmev/new/repo
#     gate  no-mistakes → /tmp/nmev/new/home/repos/90bdf17ae799.git
#   remote  ../origin.git

NM_HOME=$SCRATCH/home NO_MISTAKES_NO_UPDATE_CHECK=1 $SCRATCH/bin/no-mistakes doctor
#   System
#   ✓ git             git version 2.50.1 (Apple Git-155)
#   ✓ gh              ok
#   – az              not found (optional, needed for Azure DevOps PR/CI)
#   ✓ data directory  /tmp/nmev/new/home
#   ✓ database        ok
#   ✓ daemon          running
#   Agents
#   ✓ claude          /Users/aaron/.local/bin/claude
#   ✓ codex           /Users/aaron/.npm-global/bin/codex
#   ✓ grok            /Users/aaron/.grok/bin/grok
#   – rovodev         not found
#   – opencode        not found
#   ✓ pi              /Users/aaron/.npm-global/bin/pi
#   – copilot         not found
#   – antigravity     not found
#   – acpx            not found
#   – cursor          not found (cursor-agent, acpx)
#   ✓ gate validation  claude is runnable
```

`doctor` and `init` both report a healthy gate with no configuration complaint, and the same commands under the installed v1.64.0 produce the same output apart from the update notice.

The pinned PR-gate validator was exercised against a real attestation this fleet produced, taken from a merged firstmate pull request and its live head commit.

```sh
PR_BODY="$(...)" PR_HEAD_SHA=c764010ee83a48d8fe1d69ccc38bc0faa3dd961a PR_NUMBER=2 PR_AUTHOR=adk47 python3 verify.py
# Found no-mistakes signature in PR #2 body.
# Found structurally compliant pipeline step attestation.
```

## Upgrade

Firstmate applies this, never a crewmate and never a pipeline worker, and only at a moment when no run is mid-gate.
This fleet has no quiet windows, so that moment is made, not waited for: firstmate holds new gate launches for a bounded window, lets the runs already in flight drain, and applies the update inside that window or releases the hold and tries again later.

The guard is built into the updater rather than reimplemented: when any pipeline run is pending or running, `update` refuses to restart the daemon and prints each active run's ID, status, branch, and short head SHA, and `-y`/`--yes` does not bypass that refusal.
`no-mistakes daemon stop` and `no-mistakes daemon restart` apply the same guard.
So the detection step is the upgrade command itself, run without `--force`, inside the hold:

```sh
# 1. Start the hold. Firstmate stops sending the validate step to any crewmate
#    and stops dispatching new work that would reach a gate; a crewmate that has
#    finished its implementation commit is told to hold `no-mistakes axi run`
#    until released. Runs already active keep going and are driven to their
#    next gate or outcome by their own workers as usual.
#    Note the hold start time; the window is 45 minutes from here.

# 2. Attempt the upgrade without --force and without a bare --yes.
#    If any run is pending or running this refuses and lists them. A listed run
#    parked at a gate waiting on a decision does not drain by itself: resolve
#    that decision now under ask-user-authority, so the worker can finish it.
#    Retry this step every few minutes while the window is open.
no-mistakes update

# 3. As soon as step 2 reports no active runs, apply it non-interactively.
no-mistakes update -y

# 4. Confirm the new version and a healthy gate, then release the hold.
no-mistakes --version
no-mistakes doctor
```

When the 45-minute window closes with runs still active, release the hold without applying anything, note which runs were still listed, and schedule the next attempt for the next daily check rather than extending the window: a hold that runs on stalls the fleet, and a run that cannot drain in 45 minutes is itself something to look at.
Never pass `--force`: it accepts that the listed in-flight runs may fail.
After the upgrade, the first pipeline run in each repo is the real test of the trusted `.no-mistakes.yaml` parse, because the run resolves that file when it starts.

## Rollback

The updater keeps no durable previous binary, and the published installer always resolves the newest release, so a rollback reinstalls the pinned release asset directly.

```sh
# 1. Stop the daemon only when no pipeline run is pending or running.
no-mistakes daemon stop

# 2. Reinstall the pinned previous version over the running binary.
curl -fsSL -o /tmp/nm-rollback.tgz \
  https://github.com/kunchenguid/no-mistakes/releases/download/v1.64.0/no-mistakes-v1.64.0-darwin-arm64.tar.gz
tar -xzf /tmp/nm-rollback.tgz -C /tmp
mv /tmp/no-mistakes "$HOME/.no-mistakes/bin/no-mistakes"
chmod 755 "$HOME/.no-mistakes/bin/no-mistakes"

# 3. Confirm the rolled-back version, then refresh the version-matched skill copy
#    that init installs for agents, and restart the daemon.
no-mistakes --version
cd "$(mktemp -d)" && git init -q . && no-mistakes init
no-mistakes doctor
```

`$HOME/.local/bin/no-mistakes` is a symlink to `$HOME/.no-mistakes/bin/no-mistakes` and needs no change.
The third step matters because `init` rewrites the user-level `/no-mistakes` skill with the vendored copy of whichever binary ran it, so a rollback without it leaves the installed skill describing the newer version.

## Verification boundary

This evaluation did not run a full pipeline with v1.75.2, because that needs a real remote and spends gate-agent quota.
Specifically, it does not prove:

- that the trusted `.no-mistakes.yaml` parses under v1.75.2 at run time, which was instead checked key by key against the v1.75.2 reference schema, and which the first post-upgrade run settles.
- that a v1.75.2-written attestation passes the pinned action, which was instead established from the v1.75.2 reference documentation, the identical attestation format strings in both binaries, and the pinned validator's acceptance of a real current-format attestation.
- the live-validation behaviour of the new Test evidence agent, which was read from the v1.75.2 reference documentation rather than exercised.
