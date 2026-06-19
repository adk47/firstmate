#!/usr/bin/env bash
# codex-version.sh — SINGLE SOURCE OF TRUTH for the pinned @openclaw/codex version.
#
# Sourced by: scripts/deploy.sh (deploy-time pin), scripts/lib/ensure-codex-version-pinned.sh
# (ExecStartPre auto-heal + watchdog --check). Keeping the value in ONE place means
# the deploy pin, the runtime self-heal, and the drift alarm can never disagree.
#
# ── Why codex is pinned BELOW the runtime, NOT in lockstep ────────────────────
# The Codex agent harness ships as a separate npm package whose supports()/ABI
# tracks the core runtime. We NORMALLY keep it in lockstep with OPENCLAW_VERSION
# (openclaw 2026.5.20 made the runtime validate a forced harness's supports()
# BEFORE pinning it, so a Codex plugin OLDER than the runtime can have its
# supports() rejected → every Codex-pinned agent silently falls back. Incident
# 2026-05-29: runtime bumped 5.19 -> 5.27 but the 5.19 Codex plugin stayed, so
# ceo/cto/qa/operations/devops/design rejected openai/gpt-5.5 and ran on Sonnet).
#
# DELIBERATE EXCEPTION (2026-06-16): codex is pinned to 2026.5.27 — BELOW the
# 2026.6.1 runtime. @openclaw/codex@2026.6.x's "OpenAI route unification"
# regressed openai/gpt-5.5 onto the OpenAI Responses API-KEY route
# (api.openai.com/v1/responses) instead of the Codex app-server OAuth route
# (chatgpt.com/backend-api/codex/responses) — upstream #90925 / #90448, both
# still OPEN as of openclaw 2026.6.6. hydra is OAuth-only (only a PLACEHOLDER
# OPENAI_API_KEY), so those mis-routed calls 401 `invalid_api_key` and the whole
# fleet falls back to openrouter/gpt-5.4-mini (incident 2026-06-19, when a manual
# `plugins install @openclaw/codex@2026.6.1 --force` floated codex off this pin).
# We VERIFIED on node-8 that codex@5.27 runs CLEAN on the 6.1 core: serves
# openai/gpt-5.5 with no supports() rejection and ZERO #90925 401s. 5.27 is the
# newest Codex build without #90925 that still ABI-loads on this core.
#
# Revert to "${OPENCLAW_VERSION}" lockstep ONLY once #90925 ships fixed in a core
# release we run. Until then: NEVER `plugins install`/`update` codex off this pin
# — the ExecStartPre healer (ensure-codex-version-pinned.sh) reverts a float on
# the next gateway restart, and the watchdog pages on drift.
#
# Env override (CI / one-off) honored, same as the other pins in deploy.sh.
OPENCLAW_CODEX_VERSION="${OPENCLAW_CODEX_VERSION:-2026.5.27}"
export OPENCLAW_CODEX_VERSION
