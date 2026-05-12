#!/usr/bin/env bash
# scripts/lib/plugin-env.sh
#
# Plugin helpers extracted from scripts/deploy.sh (2026-05-12 PR for the
# Deploy HYDRA #163 incident). Source this file from any script that
# needs to enumerate plugin→profile mappings or validate that a profile's
# env-file holds every secret the plugin's config references.
#
# Two consumers today:
#   - scripts/deploy.sh         (Step 4d plugin install — production deploy)
#   - .github/workflows/pr-validate.yml (deploy-preflight job — PR-time gate)
#
# Functions exported:
#   plugin_profile <plugin_name>            → echoes "main edge"-style list
#   verify_plugin_env_for_profile <plugin> <profile> <repo_root>
#                                            → returns 0 OK / 1 missing vars
#
# The verify function expects a `log` function. If the caller hasn't
# defined one (e.g., PR-time job sourcing the lib directly), we provide
# a minimal fallback that matches deploy.sh's format closely enough that
# the error messages stay consistent across both call sites.

if ! declare -F log >/dev/null 2>&1; then
  log() { echo "[$(date -u '+%Y-%m-%dT%H:%M:%SZ')] $*"; }
fi

# plugin_profile — returns the target profile(s) for a given plugin name.
# Stdout is a space-separated list of profiles (caller iterates);
# diagnostic notices go to stderr to avoid polluting the captured value.
#
#   intercom       → "main edge"
#   support-tools  → "main edge"
#   openclaw-gmail → "main"
#   everything else → "main" (with a stderr warning so typos surface)
#
# History: intercom was previously mapped to "edge" only, which caused
# /root/.openclaw-main/extensions/intercom to drift missing even though
# openclaw-main.json pins intercom in plugins.load.paths. The main gateway
# crashlooped with "plugin path not found" on 2026-04-24 (deploy of PR #170)
# until the plugin dir was hot-patched in. See memory
# project_deploy_plugin_path_drift.md.
plugin_profile() {
  local plugin_name="$1"
  case "$plugin_name" in
    intercom)                          echo "main edge" ;;
    support-tools)                     echo "main edge" ;;
    openclaw-gmail)                    echo "main" ;;
    muso-credit-verification-enforcer) echo "main" ;;
    *)
      echo "main"
      echo "    plugin_profile: '$plugin_name' is not in the known mapping (intercom→main+edge, support-tools→main+edge, openclaw-gmail→main, muso-credit-verification-enforcer→main); defaulting to main. Verify this is intended — typos in plugin directory names land here silently." >&2
      ;;
  esac
}

# verify_plugin_env_for_profile — fails (returns 1) if any env-source secret
# reference under plugins.entries[plugin].config is not present in
# /etc/openclaw/shared.env or /etc/openclaw/<profile>.env. Skips silently
# when there is no plugins.entries entry for the plugin (the plugin does not
# need any env vars on that profile).
#
# If /etc/openclaw/ does not exist (dev machine, CI runner without server
# state), the check is skipped and returns 0.
verify_plugin_env_for_profile() {
  local plugin_name="$1"
  local profile="$2"
  local repo_root="$3"

  if [[ ! -d /etc/openclaw ]]; then
    log "    skip env check: /etc/openclaw not present (not on a deploy host)"
    return 0
  fi

  local config_file="${repo_root}/openclaw-${profile}.json"
  if [[ ! -f "$config_file" ]]; then
    log "    skip env check: $config_file not present"
    return 0
  fi

  if ! command -v jq >/dev/null 2>&1; then
    log "    ✗ jq is required for env-var verification but is not installed"
    return 1
  fi

  local refs
  refs=$(jq -r --arg p "$plugin_name" \
    '.plugins.entries[$p].config // empty
     | to_entries[]?
     | select(.value | type == "object")
     | select(.value.source == "env")
     | .value.id' \
    "$config_file" 2>/dev/null | sort -u)

  if [[ -z "$refs" ]]; then
    return 0
  fi

  local shared_env="/etc/openclaw/shared.env"
  local profile_env="/etc/openclaw/${profile}.env"
  local missing=()
  while IFS= read -r var; do
    [[ -z "$var" ]] && continue
    if grep -qE "^${var}=" "$shared_env" 2>/dev/null \
    || grep -qE "^${var}=" "$profile_env" 2>/dev/null; then
      continue
    fi
    missing+=("$var")
  done <<< "$refs"

  if (( ${#missing[@]} > 0 )); then
    log "    ✗ Plugin $plugin_name on profile '$profile' needs these env vars but they are not in $shared_env or $profile_env:"
    printf '        - %s\n' "${missing[@]}"
    log "      Remediation: add the missing variables to $profile_env (or move them to $shared_env if they should be visible to all profiles), then 'systemctl daemon-reload && systemctl restart openclaw-gateway-${profile}.service' before re-running deploy."
    return 1
  fi

  return 0
}
