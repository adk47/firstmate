#!/usr/bin/env bash
# qa-review-gateway pod entrypoint (node8-to-pods T9, 2026-10-28).
#
# One pod = one OpenClaw gateway that runs ONLY the `qa` agent, so PR reviews
# stop sharing Caroline's event loop on node-8. The Deployment, Service, HPA and
# policies live in H-DevOps k8s/prod/hydra-qa/; this file is what each pod runs.
#
# Order matters, and every step fails closed (a pod that cannot boot correctly
# must CrashLoop, visibly, rather than serve reviews on the paid openrouter
# fallback or with a borrowed token):
#   1. refuse a gateway token that is short, or is one of Caroline's literals
#      (openclaw-main.json / openclaw-edge.json carry plaintext tokens that
#      already authenticate from the public internet; security-arch-fable-s1)
#   2. install the profile into the pod's own state dir and validate it
#   3. `openclaw doctor --non-interactive` creates the state schema (safe
#      migrations only). NEVER `--fix`/`--repair`: on 2026.8 that fans the codex
#      profile out into every agent store (the 2026-05-29 fleet incident)
#   4. import the codex ACCESS credentials from the mounted Secret
#      (scripts/codex-auth-secret.sh refuses anything but the sentinel refresh slot)
#   5. exec the gateway
#
# Env (set by the Deployment):
#   OPENCLAW_STATE_DIR      the pod's state dir (an emptyDir); required
#   OPENCLAW_GATEWAY_TOKEN  this gateway's OWN token (ESO, Vault secret/k8s/hydra-qa/gateway)
#   QA_CODEX_AUTH_FILE      default /var/run/qa-codex-auth/auth-profiles.store.json
#   HYDRA_ROOT              default /opt/hydra
#   OPENCLAW                default openclaw
set -euo pipefail

HYDRA_ROOT="${HYDRA_ROOT:-/opt/hydra}"
OPENCLAW="${OPENCLAW:-openclaw}"
PROFILE_SRC="${QA_GATEWAY_PROFILE:-$HYDRA_ROOT/k8s/prod/qa-review-gateway/openclaw-qa.json}"
AUTH_FILE="${QA_CODEX_AUTH_FILE:-/var/run/qa-codex-auth/auth-profiles.store.json}"
PORT="${QA_GATEWAY_PORT:-18789}"

log() { echo "[qa-review-gateway $(date -u +%Y-%m-%dT%H:%M:%SZ)] $*" >&2; }
die() { log "FATAL: $*"; exit 1; }

: "${OPENCLAW_STATE_DIR:?OPENCLAW_STATE_DIR is required (the pod emptyDir)}"
[ -n "${OPENCLAW_GATEWAY_TOKEN:-}" ] || die "OPENCLAW_GATEWAY_TOKEN is empty — the gateway would bind the LAN with no auth"
[ "${#OPENCLAW_GATEWAY_TOKEN}" -ge 32 ] || die "OPENCLAW_GATEWAY_TOKEN is shorter than 32 chars"
for cfg in "$HYDRA_ROOT/openclaw-main.json" "$HYDRA_ROOT/openclaw-edge.json"; do
  [ -r "$cfg" ] || continue
  lit="$(jq -r '.gateway.auth.token // empty' "$cfg" 2>/dev/null || true)"
  [ -n "$lit" ] && [ "$lit" = "$OPENCLAW_GATEWAY_TOKEN" ] \
    && die "OPENCLAW_GATEWAY_TOKEN equals the gateway token in $(basename "$cfg") — the QA gateway must have its own (Vault secret/k8s/hydra-qa/gateway)"
done
unset lit

[ -r "$PROFILE_SRC" ] || die "profile not found: $PROFILE_SRC"
[ -r "$AUTH_FILE" ] || die "codex auth Secret not mounted at $AUTH_FILE (Secret hydra-qa/qa-codex-auth, written by the codex-auth-secret-writer CronJob)"

mkdir -p "$OPENCLAW_STATE_DIR"
install -m 0600 "$PROFILE_SRC" "$OPENCLAW_STATE_DIR/openclaw.json"
export OPENCLAW_CONFIG_PATH="$OPENCLAW_STATE_DIR/openclaw.json"
# A profile/port override in the env would point the CLI at another store.
unset OPENCLAW_PROFILE OPENCLAW_GATEWAY_URL OPENCLAW_GATEWAY_PORT

"$OPENCLAW" config validate >/dev/null || die "openclaw config validate rejected $PROFILE_SRC"
"$OPENCLAW" doctor --non-interactive >&2 || die "openclaw doctor --non-interactive failed (state schema not created)"
bash "$HYDRA_ROOT/scripts/codex-auth-secret.sh" import --in "$AUTH_FILE" >&2 \
  || die "codex auth import refused — not starting on the openrouter fallback"

log "starting gateway on :$PORT (profile $(basename "$PROFILE_SRC"), state $OPENCLAW_STATE_DIR)"
exec "$OPENCLAW" gateway --port "$PORT"
