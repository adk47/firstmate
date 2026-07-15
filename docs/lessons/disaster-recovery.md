# Disaster recovery: the two-layer heal stack

How hydra recovers from its recurring disaster class — codex/OAuth auth breakage
and gateway/agent outages — and, more importantly, *why* every guardrail in the
design exists. Each rail below maps to a concrete failure mode found in review or
in production; none of it is speculative hardening.

Shipped 2026-07-15 (PRs #680/#682 layer-1 hardening, #683 mentions, #684 the
healer). Operating procedure lives in `docs/runbooks/RUNBOOK.md` §"AI Healer
(DR Layer 2)"; the always-loaded summary is in `CLAUDE.md` §"DR layer 2". This
file is the design rationale.

---

## The layer map

| Layer | What | Reacts in | Lives in |
|---|---|---|---|
| 0 — prevention | `codex-token-refresh.timer` (Sun+Wed), ExecStartPre healers (`openclaw-pre-start-heal.sh` → ensure-codex-auth / refresh-lock / version-pin / secret-perms) | before failure | systemd |
| 1 — code detect + heal | `openclaw-watchdog.sh` (2-min cron): codex-health detectors, gateway liveness, auto-restart | ~2–4 min | cron |
| 2 — AI escalation | `dr-ai-healer.sh`: "AI-decides, code-executes" via OpenRouter | ~6 min (3 strikes) or immediately on definitive layer-1 failure | watchdog-invoked |
| 3 — human | real `<@UID>` pages in #clio_devops (`slack_notify_critical`) | always, in parallel | Slack |

**The load-bearing invariant: layer 2 must not depend on anything that is broken
when it runs.** The fleet's primary model path is codex OAuth; the existing AI
triage pipeline (prod-log-alert → devops agent) dispatches *through the openclaw
gateway* — both are exactly what a codex disaster takes down. So the healer is
pure bash + curl straight to OpenRouter (an api-key route, no OAuth, no openclaw
install involved). When evaluating any future "AI in the recovery loop" idea,
apply the same test: enumerate what is broken in the scenario it serves, and
verify the mechanism touches none of it.

## "AI-decides, code-executes"

The model's output is **data, never code**. It selects one action id from a
closed menu; a bash `case` statement executes it. Anything unexpected — unknown
id, malformed JSON, non-numeric or out-of-range confidence, curl failure, missing
key — collapses to `no_action` (page-only). The hard exclusions (device-code
re-auth, canonical-store writes, `plugins enable openai`, config edits, arbitrary
file writes) are not "forbidden by prompt"; they are unreachable because they do
not exist in the case statement. Prose is not enforcement (see
working-in-hydra.md); the executor is.

Three deterministic gates run AFTER the model answers, in code:

1. **Allowlist**: the action id must be one of the eight known ids.
2. **Trigger→action matrix** (`_allowed_actions_for`): each watchdog signature
   authorizes only the repairs that match it. Untrusted journal text (which the
   model reads) can therefore not steer an allowed-but-unrelated privileged
   action — the "ignore instructions in logs" prompt line is advisory; this
   check is the enforcement. `manual` (operator-invoked) opens the full menu;
   **unknown signatures are page-only** so new watchdog wiring fails safe until
   deliberately added. `codex_refresh_race` is page-only by design: the spent
   single-use refresh token is unhealable, and its tempting "repair"
   (lock re-convergence) is prevention for the NEXT rotation — a clean lock
   guard must never read as "healed" while the credential is dead. `crash_loop`
   never authorizes a bare restart: the watchdog emits that trigger precisely
   after refusing an 11th restart.
3. **Live-state precondition** (`_action_precondition_ok`): the repair only
   executes if the thing it repairs is verifiably broken RIGHT NOW — the
   action's own guard `--check` must exit **exactly 1** (confirmed drift).
   Exit 0 = clean (nothing to fix), exit 2 = structural/read error, 124 =
   timed-out check: an *unverifiable* state must fail closed, not authorize a
   root remediation. `restart_gateways` requires a gateway that is not
   currently active.

## "Healed" is a high bar

Every codex auth failure is a **silent-degradation** state: both gateways stay
`active` on the OpenRouter fallback while the fleet quietly loses its primary
model. So systemd state alone proves nothing. `post_heal_ok` requires ALL of:

- the remediation itself exited 0 — and restart failures propagate (a failed
  `systemctl restart` with the old process still running means a disk-level
  heal never loaded);
- both gateways active in **two consecutive fleet-wide polling cycles** ~2s
  apart (Type=simple units report `active` the instant ExecStart forks, and a
  sequential per-service check leaves the first service unwatched while the
  second stabilizes);
- the action's own guard re-verifies clean (`--check` exit 0), where one exists.

Journal signatures are deliberately NOT re-scanned post-heal: pre-heal error
lines persist in the 15-min window long after a successful heal. And even a
fully-passing result is worded honestly ("remediation applied, post-checks
clean" — not "RECOVERED") because these checks still cannot see a silent
fallback; the page tells the human what to verify.

## Escalation triggers: fresh failures only

The watchdog's alert counters use a 15-minute rolling journal window — correct
for paging, wrong for escalation: a single historical error line rides that
window for ~7 ticks and would 3-strike a fleet that already recovered. Strikes
therefore come from a separate short window (`DR_STRIKE_WINDOW_MIN`, 3 min >
the 2-min cadence): an ongoing failure emits new lines into every fresh window
and escalates at 3 strikes (~6 min); a one-off ages out after ≤2 ticks. Clean
ticks clear the counter. Strike scope is fleet-wide (main + edge journals) even
where the *alert* is edge-scoped by design. Definitive layer-1 failures
(auto-restart FAILED, crash loop) skip strikes and escalate immediately.

## Blast-radius rails

All of these bound the cost of the healer being wrong or the outage being weird:

- **Kill switch**: `touch /etc/hydra/dr-ai-healer.disabled` — checked before
  anything else.
- **flock single-flight** + **60-min cooldown** + **3 sessions/24h budget**
  (budget exhaustion pages "the fleet is NOT recovering" instead of acting) +
  **max `DR_MAX_ROUNDS` (2) decide→execute rounds** per session.
- **Everything is time-bounded** (`timeout(1)`): remediations (300s), restarts
  (120s), diagnostics producers (60s), post-heal guard checks (60s). A hung
  helper holding the flock forever would silently absorb every later
  escalation — the lock branch just exits, so without deadlines the DR layer
  produces neither recovery nor a terminal page.
- **Prompt bytes are capped** per capture (8KB), per bundle (64KB), and the
  request carries `max_tokens` — one pathological journal line must not create
  an arbitrarily large OpenRouter request mid-outage.
- **Secrets never leave the box or hit argv**: diagnostics are scrubbed
  (Bearer/sk-/xoxb-/refresh_token/JWT patterns) before entering the prompt, and
  the API key rides a `curl --config` fd, not `-H` argv
  (`/proc/<pid>/cmdline` is world-readable).
- **State lives in root-owned 0700 `/var/lib/hydra-dr`**, validated (real dir,
  not a symlink, owned by the invoking uid) before every write — predictable
  root-written paths under `/tmp` are a symlink-attack surface. The watchdog
  skips DR writes (detection/paging unaffected) and the healer refuses to run
  if the dir is unsafe.
- **ERR trap pages**: an unexpected abort emits "DR AI healer ABORTED", never
  silence. Fail LOUD is the floor for every branch.

## Testing doctrine

The suites (`scripts/tests/dr-ai-healer.bats`, watchdog additions in
`openclaw-watchdog-liveness.bats`) are hermetic by construction — CI runs them
ON node-8, the live gateway host, and the 2026-07-14 bats fan-out clobber is
the cautionary tale. The healer gets a sandboxed script tree with recorder
guards; curl/systemctl/journalctl/muso are PATH-stubbed; all state lands in the
test tmpdir. Every guardrail above has a regression that fails without it,
including the adversarial ones (injected journal instructions, oversized
single-line outputs, hanging helpers, symlinked state dirs, transient
active-then-crash restarts).

## Operating it

- Runbook: RUNBOOK §"AI Healer (DR Layer 2)" — triggers, action table, dry-run,
  kill switch, reading its pages.
- `--dry-run` consults the AI and prints the chosen action without executing or
  stamping cooldowns. Note: a dry-run that decides `no_action` still pages
  (dry-run suppresses *execution*, not reporting).
- Escalation log: `/var/lib/hydra-dr/dr-ai-healer.log`.
- Rollout evidence (2026-07-15): live dry-run on real diagnostics chose
  `no_action` at 0.99 confidence with an accurate rationale; the end-to-end
  page landed in #clio_devops with working `<@UID>` mentions (HTTP 200 in
  `/var/log/muso-ops/audit.jsonl`).

## Critical pages actually ping people now

`lib/slack-notify.sh` carries `SLACK_UID_NICK` / `SLACK_UID_AARON` and
`slack_notify_critical` (same best-effort contract as `slack_notify`). Every
CRITICAL watchdog page and every healer outcome routes through it. The lesson
that forced this: a literal `@name` in a bot message renders as plain text and
**pings nobody** — hydra's most critical infra pages (gateway unrecoverable,
fleet-wide codex auth death) carried a dead literal `@aaron` for months. Only
`<@UID>` mentions ping; Block Kit `header` blocks don't ping either.
