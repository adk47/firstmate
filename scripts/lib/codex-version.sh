#!/usr/bin/env bash
# codex-version.sh — SINGLE SOURCE OF TRUTH for the pinned @openclaw/codex version.
#
# Sourced by: scripts/deploy.sh (deploy-time pin), scripts/lib/ensure-codex-version-pinned.sh
# (ExecStartPre auto-heal + watchdog --check). Keeping the value in ONE place means
# the deploy pin, the runtime self-heal, and the drift alarm can never disagree.
#
# ── Why codex is pinned in LOCKSTEP with the runtime ──────────────────────────
# The Codex agent harness ships as a separate npm package whose supports()/ABI
# tracks the core runtime. openclaw 2026.5.20 made the runtime validate a forced
# harness's supports() BEFORE pinning it, so a Codex plugin OLDER than the
# runtime can have its supports() rejected → every Codex-pinned agent silently
# falls back (incident 2026-05-29: runtime bumped 5.19 -> 5.27 but the 5.19
# Codex plugin stayed; six agents ran on Sonnet for hours). Additionally, the
# 2026.7.x first-boot doctor auto-"refreshes" a stale configured codex plugin
# to the runtime's version, so an off-lockstep pin would fight the doctor on
# every boot (observed on the 2026-07-14 staging validation).
#
# HISTORY — the 2026.5.27 hold (2026-06-16 → 2026-07-14): codex was deliberately
# pinned BELOW the 2026.6.1 runtime because @openclaw/codex@2026.6.x's "OpenAI
# route unification" (#90925/#90448) regressed openai/gpt-5.5 onto the api-key
# Responses route; hydra is OAuth-only, so the fleet 401'd `invalid_api_key`
# (incident 2026-06-19). RESOLVED for 2026.7.1: staging validation on node-8
# (2026-07-14) confirmed codex@2026.7.1 on the 2026.7.1 core serves
# openai/gpt-5.5 via ChatGPT OAuth end-to-end — PROVIDED each agent's
# codex-home/auth.json is in chatgpt mode (see scripts/lib/codex-auth-sync.sh;
# the old apikey-mode file with a placeholder OPENAI_API_KEY reproduces the
# 401s). NOTE the route tell changed in 7.x: BOTH auth modes now target
# api.openai.com/v1/responses — OAuth uses the websocket (wss://) transport
# with a ChatGPT Bearer token; api-key uses HTTP. `chatgpt.com/backend-api/…`
# no longer appears; do not use the old URL tell to diagnose.
#
# NEVER `plugins install`/`update` codex off this pin — the ExecStartPre healer
# (ensure-codex-version-pinned.sh) reverts a float on the next gateway restart,
# and the watchdog pages on drift. To move codex, bump THIS file (normally in
# lockstep with OPENCLAW_VERSION in deploy.sh).
#
# ── Runtime-aware resolution (the merge→upgrade hazard window) ────────────────
# Between merging a runtime bump and actually upgrading node-8 (a manual,
# windowed procedure — docs/runbooks/UPGRADE-2026.7.1.md,
# docs/runbooks/UPGRADE-2026.8.1.md), the rsynced repo carries the NEW pin
# while the box still runs the OLD core. Any gateway restart in that window
# re-runs the ExecStartPre pin healer — a static pin at the new version would
# install a mismatched codex plugin onto the old core (an untested mix, and
# for the 6.x/7.x boundary specifically, 6.x codex on this host means #90925
# 401s). So the pin resolves against the runtime it will actually serve:
#   - deploy.sh sets OPENCLAW_VERSION before sourcing this file → the pin
#     matches the runtime the SAME deploy installs at Step 4c.5 (before the
#     plugin step 4d consumes the pin);
#   - the ExecStartPre healer / watchdog have no OPENCLAW_VERSION → the pin
#     resolves against the INSTALLED `openclaw --version`, so a box heals to
#     the pin for whichever rung it is actually running, on either side of
#     any upgrade window.
# Env override (CI / one-off) still wins, same as the other pins in deploy.sh.
#
# Ladder (checked most-specific-first — a >=2026.8 runtime also satisfies
# version_at_least "2026.7", so 2026.8 MUST be tested before it):
#   >= 2026.8  -> 2026.8.2  (2.0 upgrade window — docs/runbooks/UPGRADE-2026.8.1.md;
#                            2026.8.2 is the correction release, staging-validated
#                            2026-09-01: fixes the exec-approvals doctor abort and
#                            folds session import into plain `doctor --fix`)
#   >= 2026.7  -> 2026.7.1  (staging-validated 2026-07-14, see history above)
#   otherwise  -> 2026.5.27 (the #90925 dodge, held for pre-7.x cores)
# shellcheck source=version-compare.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/version-compare.sh"
if [ -z "${OPENCLAW_CODEX_VERSION:-}" ]; then
  _codex_pin_ref="${OPENCLAW_VERSION:-$(openclaw_runtime_version)}"
  if [ -n "$_codex_pin_ref" ] && version_at_least "2026.8" "$_codex_pin_ref"; then
    OPENCLAW_CODEX_VERSION="2026.8.2"
  elif [ -n "$_codex_pin_ref" ] && version_at_least "2026.7" "$_codex_pin_ref"; then
    OPENCLAW_CODEX_VERSION="2026.7.1"
  else
    # Unknown or pre-2026.7 runtime: hold the last version verified clean on
    # the 6.1 core (the #90925 dodge).
    OPENCLAW_CODEX_VERSION="2026.5.27"
  fi
  unset _codex_pin_ref
fi
export OPENCLAW_CODEX_VERSION
